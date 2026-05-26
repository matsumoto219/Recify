require 'rails_helper'

RSpec.describe 'Admin user operations', type: :request do
  include ActiveJob::TestHelper

  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    original_show_detailed_exceptions = Rails.application.env_config['action_dispatch.show_detailed_exceptions']
    original_adapter = ActiveJob::Base.queue_adapter

    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs

    example.run
  ensure
    clear_enqueued_jobs
    ActiveJob::Base.queue_adapter = original_adapter
    Rails.application.env_config['action_dispatch.show_exceptions'] = original_show_exceptions
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = original_show_detailed_exceptions
  end

  def stub_fresh_admin_reauthentication
    allow_any_instance_of(Admin::UserOperationsController).to receive(:admin_passkey_reauthenticated?).and_return(true)
    allow_any_instance_of(Admin::UserOperationsController).to receive(:admin_reauthentication_context).and_return(
      method: 'passkey',
      reauthenticated_at: Time.current
    )
  end

  describe 'POST /admin/users/:id/operations/lock' do
    it '非adminには既存404を返す' do
      user = create(:user)
      target = create(:user)
      sign_in user

      post lock_operation_admin_user_path(target),
           params: { reason: 'support request', confirmation: 'LOCK USER' }

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include(I18n.t('errors.not_found.title'))
      end
    end

    it 'fresh reauthなしではSystemOperationsを呼ばずreauthへredirectする' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      allow(SystemOperations).to receive(:execute_user_operation)

      post lock_operation_admin_user_path(target),
           params: { reason: 'support request', confirmation: 'LOCK USER' }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_user_path(target)))
        expect(SystemOperations).not_to have_received(:execute_user_operation)
      end
    end

    it 'reason blankではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:execute_user_operation)

      post lock_operation_admin_user_path(target),
           params: { reason: ' ', confirmation: 'LOCK USER' }

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(SystemOperations).not_to have_received(:execute_user_operation)
      end
    end

    it 'fresh reauth + reason + confirmationでSystemOperations経由で実行する' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      stub_fresh_admin_reauthentication
      result = SystemOperations::Result.new(success: true)
      allow(SystemOperations).to receive(:execute_user_operation).and_return(result)

      post lock_operation_admin_user_path(target),
           params: { reason: 'support request', confirmation: 'LOCK USER' }

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(SystemOperations).to have_received(:execute_user_operation).with(
          operation: 'lock_user',
          user: target,
          actor: admin,
          reason: 'support request',
          request: kind_of(ActionDispatch::Request),
          reauthentication: hash_including(method: 'passkey', reauthenticated_at: kind_of(ActiveSupport::TimeWithZone)),
          confirmation: 'LOCK USER'
        )
      end
    end

    it '実SystemOperations経由でロックし、AuditLogを作成する' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post lock_operation_admin_user_path(target),
             params: { reason: 'support request', confirmation: 'LOCK USER' }
      end.to change(AuditLog, :count).by(1)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(target.reload.locked_at).to be_present
        expect(audit_log).to have_attributes(
          actor_user: admin,
          action: 'admin.users.lock',
          outcome: 'succeeded',
          target_uid: "user:#{target.id}"
        )
        expect(audit_log.attributes.to_json).not_to include('credential_id', 'public_key', 'challenge')
      end
    end
  end

  describe 'POST /admin/users/:id/operations/unlock' do
    it 'fresh reauth + reason + confirmationでロック解除する' do
      admin = create(:user, :admin)
      target = create(:user)
      target.lock_access!(send_instructions: false)
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post unlock_operation_admin_user_path(target),
             params: { reason: 'unlock support request', confirmation: 'UNLOCK USER' }
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(target.reload.locked_at).to be_nil
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.unlock',
          outcome: 'succeeded',
          target_uid: "user:#{target.id}"
        )
      end
    end

    it 'confirmation不一致はSystemOperationsで拒否し、failed auditを残す' do
      admin = create(:user, :admin)
      target = create(:user)
      target.lock_access!(send_instructions: false)
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post unlock_operation_admin_user_path(target),
             params: { reason: 'unlock support request', confirmation: 'WRONG' }
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(target.reload.locked_at).to be_present
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.unlock',
          outcome: 'failed',
          error_code: 'confirmation_required'
        )
      end
    end
  end
end
