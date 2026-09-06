require 'rails_helper'

RSpec.describe 'Notification limit cleanup after setting commit' do
  self.use_transactional_tests = false

  def update_limit(value)
    SystemOperations.update_setting(
      key: 'limits.notifications_per_user',
      value: value.to_s,
      actor: @actor,
      reason: 'adjust notification retention',
      request: @request,
      reauthentication: @reauthentication
    )
  end

  def reset_limit
    SystemOperations.reset_setting(
      key: 'limits.notifications_per_user',
      actor: @actor,
      reason: 'restore notification retention',
      request: @request,
      reauthentication: @reauthentication
    )
  end

  before do
    @actor = create(:user, :admin)
    @request = instance_double(ActionDispatch::Request, request_id: 'notification-limit', remote_ip: '127.0.0.1', user_agent: 'Notification Limit Spec')
    @reauthentication = {
      method: 'passkey',
      reauthenticated_at: Time.current,
      user_id: @actor.id,
      session_version: @actor.session_version,
      expires_at: Time.current + Admin.passkey_reauth_window_duration
    }
    allow(NotificationCleanupJob).to receive(:perform_later)
    expect(Notification).not_to receive(:cleanup_old!)
    expect(Notification).not_to receive(:prune_for_user!)
  end

  after do
    SystemSetting.where(key: 'limits.notifications_per_user').delete_all
    AuditLog.where(actor_user_id: @actor&.id).delete_all
    User.where(id: @actor&.id).destroy_all
  end

  it '上限引下げは外側transactionの成功commit後に一度enqueueする' do
    SystemSetting.transaction do
      expect(update_limit(20)).to be_success
      expect(NotificationCleanupJob).not_to have_received(:perform_later)
    end

    expect(NotificationCleanupJob).to have_received(:perform_later).once
  end

  it '低いdefaultへのresetも成功commit後にenqueueする' do
    create(:system_setting, key: 'limits.notifications_per_user', value: SystemSettings.stored_value(500))

    SystemSetting.transaction do
      expect(reset_limit).to be_success
      expect(NotificationCleanupJob).not_to have_received(:perform_later)
    end

    expect(NotificationCleanupJob).to have_received(:perform_later).once
  end

  it '上限引上げ・同値保存・高いdefaultへのresetではenqueueしない' do
    expect(update_limit(500)).to be_success
    expect(update_limit(500)).to be_success
    SystemSetting.find_by!(key: 'limits.notifications_per_user').update!(value: SystemSettings.stored_value(20))
    expect(reset_limit).to be_success

    expect(NotificationCleanupJob).not_to have_received(:perform_later)
  end

  [ :update, :reset ].each do |operation|
    it "#{operation}のcommit後enqueueが失敗しても設定と成功監査を失敗扱いにしない" do
      create(:system_setting, key: 'limits.notifications_per_user', value: SystemSettings.stored_value(500))
      allow(NotificationCleanupJob).to receive(:perform_later).and_raise(StandardError, 'private queue endpoint')
      allow(Rails.logger).to receive(:warn)

      result = operation == :update ? update_limit(20) : reset_limit

      aggregate_failures do
        expect(result).to be_success
        expect(SystemSettings.limit_for('limits.notifications_per_user')).to eq(operation == :update ? 20 : 100)
        expect(AuditLog.where(actor_user_id: @actor.id).pluck(:outcome)).to eq([ 'succeeded' ])
        expect(Rails.logger).to have_received(:warn).with('[NotificationCleanupJob] enqueue_failed error_class=StandardError').once
      end
    end

    it "#{operation}の外側commit後enqueueが失敗しても外側transactionを失敗扱いにしない" do
      create(:system_setting, key: 'limits.notifications_per_user', value: SystemSettings.stored_value(500))
      allow(NotificationCleanupJob).to receive(:perform_later).and_raise(StandardError, 'private queue endpoint')
      allow(Rails.logger).to receive(:warn)

      expect {
        SystemSetting.transaction do
          expect(operation == :update ? update_limit(20) : reset_limit).to be_success
        end
      }.not_to raise_error

      aggregate_failures do
        expect(SystemSettings.limit_for('limits.notifications_per_user')).to eq(operation == :update ? 20 : 100)
        expect(AuditLog.where(actor_user_id: @actor.id).pluck(:outcome)).to eq([ 'succeeded' ])
        expect(Rails.logger).to have_received(:warn).with('[NotificationCleanupJob] enqueue_failed error_class=StandardError').once
      end
    end

    it "#{operation}のenqueueがfalseを返しても成功済み設定を保持し配信失敗だけを記録する" do
      create(:system_setting, key: 'limits.notifications_per_user', value: SystemSettings.stored_value(500))
      allow(NotificationCleanupJob).to receive(:perform_later).and_return(false)
      allow(Rails.logger).to receive(:warn)

      result = operation == :update ? update_limit(20) : reset_limit

      aggregate_failures do
        expect(result).to be_success
        expect(SystemSettings.limit_for('limits.notifications_per_user')).to eq(operation == :update ? 20 : 100)
        expect(AuditLog.where(actor_user_id: @actor.id).pluck(:outcome)).to eq([ 'succeeded' ])
        expect(Rails.logger).to have_received(:warn).with('[NotificationCleanupJob] enqueue_failed').once
      end
    end

    it "#{operation}の外側transaction rollbackではenqueueしない" do
      create(:system_setting, key: 'limits.notifications_per_user', value: SystemSettings.stored_value(500))

      SystemSetting.transaction do
        expect(operation == :update ? update_limit(20) : reset_limit).to be_success
        raise ActiveRecord::Rollback
      end

      expect(SystemSettings.limit_for('limits.notifications_per_user')).to eq(500)
      expect(NotificationCleanupJob).not_to have_received(:perform_later)
    end
  end

  it 'validation失敗ではenqueueせず元の上限を維持する' do
    expect(update_limit(1)).to be_failure

    expect(SystemSettings.limit_for('limits.notifications_per_user')).to eq(100)
    expect(NotificationCleanupJob).not_to have_received(:perform_later)
  end

  it '成功監査がrollbackした場合はenqueueせず元の上限を維持する' do
    allow(AuditLogs).to receive(:record_admin_action!).and_wrap_original do |original, **attributes|
      raise ActiveRecord::RecordInvalid if attributes[:outcome] == 'succeeded'

      original.call(**attributes)
    end

    expect(update_limit(20)).to be_failure

    expect(SystemSettings.limit_for('limits.notifications_per_user')).to eq(100)
    expect(NotificationCleanupJob).not_to have_received(:perform_later)
  end
end
