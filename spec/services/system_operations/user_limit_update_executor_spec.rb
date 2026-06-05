require 'rails_helper'

RSpec.describe SystemOperations::UserLimitUpdateExecutor do
  include ActiveSupport::Testing::TimeHelpers

  let(:actor) { create(:user, :admin) }
  let(:target_user) { create(:user) }
  let(:request) { instance_double(ActionDispatch::Request, request_id: 'limit-request-id', remote_ip: '127.0.0.1', user_agent: 'User Limit Spec') }
  let(:reauthenticated_at) { Time.current }
  let(:reauthentication) do
    {
      method: 'passkey',
      reauthenticated_at: reauthenticated_at,
      credential_id: 'credential-secret',
      public_key: 'public-key-secret',
      challenge: 'challenge-secret'
    }
  end

  around do |example|
    travel_to(Time.zone.parse('2026-05-27 11:00:00')) { example.run }
  end

  describe '.call' do
    it 'ユーザー別上限overrideを作成し、success auditを保存する' do
      result = described_class.call(
        user: target_user,
        key: 'receipt_uploads_per_day',
        value: '75',
        enabled: '1',
        expires_at: '2026-06-01 12:00:00',
        actor: actor,
        reason: 'support request limit increase',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'UPDATE USER LIMIT'
      )

      override = result.user_limit_override
      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_success
        expect(override).to have_attributes(
          user: target_user,
          key: 'receipt_uploads_per_day',
          enabled: true,
          created_by_user: actor,
          updated_by_user: actor
        )
        expect(override.integer_value).to eq(75)
        expect(override.expires_at).to eq(Time.zone.parse('2026-06-01 12:00:00'))
        expect(audit_log).to have_attributes(
          actor_user: actor,
          actor_kind: 'admin',
          action: 'admin.users.limit_update',
          outcome: 'succeeded',
          target_type: 'User',
          target_id: target_user.id,
          target_uid: "user:#{target_user.id}",
          reason: 'support request limit increase',
          request_id: 'limit-request-id',
          user_agent: 'User Limit Spec'
        )
        expect(audit_log.metadata).to include(
          'key' => 'receipt_uploads_per_day',
          'enabled' => true,
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey',
          'reauthenticated_at' => reauthenticated_at.iso8601
        )
        expect(audit_log.before_state).to include(
          'user_id' => target_user.id,
          'key' => 'receipt_uploads_per_day',
          'limit_value' => 50,
          'source' => 'global_default'
        )
        expect(audit_log.after_state).to include(
          'user_id' => target_user.id,
          'key' => 'receipt_uploads_per_day',
          'limit_value' => 75,
          'source' => 'override',
          'override_enabled' => true,
          'override_value' => 75
        )
        expect(audit_log.attributes.to_json).not_to include('credential-secret', 'public-key-secret', 'challenge-secret')
        expect(audit_log.attributes.to_json).not_to include('secret', 'token', 'session_uid', 'raw_response', 'prompt')
      end
    end

    it '既存overrideをdisabled化できる' do
      override = create(:user_limit_override, user: target_user, key: 'ocr_jobs_per_day', value: { 'value' => 90 })

      result = described_class.call(
        user: target_user,
        key: 'ocr_jobs_per_day',
        value: '90',
        enabled: '0',
        expires_at: nil,
        actor: actor,
        reason: 'disable temporary limit',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'UPDATE USER LIMIT'
      )

      aggregate_failures do
        expect(result).to be_success
        expect(override.reload.enabled).to be(false)
        expect(result.after_state).to include(source: 'global_default', override_enabled: false, override_value: 90)
        expect(AuditLog.last.after_state).to include('source' => 'global_default', 'override_enabled' => false, 'override_value' => 90)
      end
    end

    it 'reauthentication nilを拒否する' do
      result = described_class.call(
        user: target_user,
        key: 'receipt_uploads_per_day',
        value: '75',
        enabled: '1',
        expires_at: nil,
        actor: actor,
        reason: 'missing reauth',
        request: request,
        reauthentication: nil,
        confirmation: 'UPDATE USER LIMIT'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('reauthentication_required')
        expect(UserLimitOverride.where(user: target_user)).to be_empty
        expect(AuditLog.last).to have_attributes(action: 'admin.users.limit_update', outcome: 'failed', error_code: 'reauthentication_required')
      end
    end

    it 'reason blankを拒否する' do
      result = described_class.call(
        user: target_user,
        key: 'receipt_uploads_per_day',
        value: '75',
        enabled: '1',
        expires_at: nil,
        actor: actor,
        reason: ' ',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'UPDATE USER LIMIT'
      )

      expect(result.error_code).to eq('reason_required')
    end

    it 'confirmation不一致を拒否する' do
      result = described_class.call(
        user: target_user,
        key: 'receipt_uploads_per_day',
        value: '75',
        enabled: '1',
        expires_at: nil,
        actor: actor,
        reason: 'wrong confirmation',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'WRONG'
      )

      expect(result.error_code).to eq('confirmation_required')
    end

    it 'unknown keyを拒否する' do
      result = described_class.call(
        user: target_user,
        key: 'secret.provider_api_key',
        value: '75',
        enabled: '1',
        expires_at: nil,
        actor: actor,
        reason: 'bad key',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'UPDATE USER LIMIT'
      )

      aggregate_failures do
        expect(result.error_code).to eq('unknown_key')
        expect(AuditLog.last.metadata).to include('key' => 'unknown')
      end
    end

    it 'value範囲外を拒否する' do
      result = described_class.call(
        user: target_user,
        key: 'retry_operations_per_day',
        value: '500',
        enabled: '1',
        expires_at: nil,
        actor: actor,
        reason: 'too high',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'UPDATE USER LIMIT'
      )

      expect(result.error_code).to eq('above_max')
    end

    it 'snapshot OCR/AI上限を超えるreceipt_items_per_receipt overrideを拒否する' do
      result = described_class.call(
        user: target_user,
        key: 'receipt_items_per_receipt',
        value: '1200',
        enabled: '1',
        expires_at: nil,
        actor: actor,
        reason: 'raise item limit',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'UPDATE USER LIMIT'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('receipt_items_snapshot_limit')
        expect(UserLimitOverride.where(user: target_user, key: 'receipt_items_per_receipt')).to be_empty
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.limit_update',
          outcome: 'failed',
          error_code: 'receipt_items_snapshot_limit'
        )
      end
    end

    it 'snapshot OCR/AI上限以下ならreceipt_items_per_receipt overrideを作成できる' do
      create(:system_setting, key: 'limits.snapshot_ocr_items_max', value: SystemSettings.stored_value(1500))
      create(:system_setting, key: 'limits.snapshot_ai_normalized_items_max', value: SystemSettings.stored_value(1500))

      result = described_class.call(
        user: target_user,
        key: 'receipt_items_per_receipt',
        value: '1200',
        enabled: '1',
        expires_at: nil,
        actor: actor,
        reason: 'raise item limit after snapshot limits',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'UPDATE USER LIMIT'
      )

      aggregate_failures do
        expect(result).to be_success
        expect(result.user_limit_override.integer_value).to eq(1200)
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.limit_update',
          outcome: 'succeeded'
        )
      end
    end

    it 'admin自身の増枠を許可する' do
      actor.update!(storage_limit_bytes: 1.gigabyte)

      result = described_class.call(
        user: actor,
        key: 'storage_bytes',
        value: 2.gigabytes.to_s,
        enabled: '1',
        expires_at: nil,
        actor: actor,
        reason: 'self increase',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'UPDATE USER LIMIT'
      )

      aggregate_failures do
        expect(result).to be_success
        expect(result.user_limit_override.integer_value).to eq(2.gigabytes)
        expect(AuditLog.last).to have_attributes(
          actor_user: actor,
          action: 'admin.users.limit_update',
          outcome: 'succeeded',
          target_id: actor.id,
          target_uid: "user:#{actor.id}"
        )
      end
    end

    it '非admin自身の増枠は防御的に拒否する' do
      non_admin = create(:user, storage_limit_bytes: 1.gigabyte)

      result = described_class.call(
        user: non_admin,
        key: 'storage_bytes',
        value: 2.gigabytes.to_s,
        enabled: '1',
        expires_at: nil,
        actor: non_admin,
        reason: 'self increase',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'UPDATE USER LIMIT'
      )

      expect(result.error_code).to eq('self_limit_increase_forbidden')
    end

    it '他admin targetを拒否する' do
      admin_target = create(:user, :admin)

      result = described_class.call(
        user: admin_target,
        key: 'receipt_uploads_per_day',
        value: '75',
        enabled: '1',
        expires_at: nil,
        actor: actor,
        reason: 'admin target',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'UPDATE USER LIMIT'
      )

      expect(result.error_code).to eq('admin_target_forbidden')
    end
  end
end
