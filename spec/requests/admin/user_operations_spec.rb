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
    [ Admin::UsersController, Admin::UserOperationsController ].each do |controller|
      allow_any_instance_of(controller).to receive(:admin_passkey_reauthenticated?).and_return(true)
      allow_any_instance_of(controller).to receive(:admin_reauthentication_context).and_return(
        method: 'passkey',
        reauthenticated_at: Time.current
      )
    end
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

  describe 'POST /admin/users/:id/operations/force_passkey_reset' do
    it 'fresh reauthなしではSystemOperationsを呼ばずreauthへredirectする' do
      admin = create(:user, :admin)
      target = create(:user)
      create(:passkey, user: target)
      sign_in admin
      allow(SystemOperations).to receive(:execute_user_operation)

      post force_passkey_reset_operation_admin_user_path(target),
           params: { reason: 'passkey recovery request', confirmation: 'RESET PASSKEYS' }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_user_path(target)))
        expect(SystemOperations).not_to have_received(:execute_user_operation)
      end
    end

    it 'reason blankではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      target = create(:user)
      create(:passkey, user: target)
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:execute_user_operation)

      post force_passkey_reset_operation_admin_user_path(target),
           params: { reason: ' ', confirmation: 'RESET PASSKEYS' }

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(SystemOperations).not_to have_received(:execute_user_operation)
      end
    end

    it 'fresh reauth + reason + confirmationでSystemOperations経由で実行する' do
      admin = create(:user, :admin)
      target = create(:user)
      create(:passkey, user: target)
      sign_in admin
      stub_fresh_admin_reauthentication
      result = SystemOperations::Result.new(success: true)
      allow(SystemOperations).to receive(:execute_user_operation).and_return(result)

      post force_passkey_reset_operation_admin_user_path(target),
           params: { reason: 'passkey recovery request', confirmation: 'RESET PASSKEYS' }

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(SystemOperations).to have_received(:execute_user_operation).with(
          operation: 'force_passkey_reset',
          user: target,
          actor: admin,
          reason: 'passkey recovery request',
          request: kind_of(ActionDispatch::Request),
          reauthentication: hash_including(method: 'passkey', reauthenticated_at: kind_of(ActiveSupport::TimeWithZone)),
          confirmation: 'RESET PASSKEYS'
        )
      end
    end

    it '実SystemOperations経由でpasskeysを削除し、credential情報を出さない' do
      admin = create(:user, :admin)
      target = create(:user)
      passkey = create(:passkey, user: target, credential_id: 'credential-secret', public_key: 'PUBLIC KEY SECRET')
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post force_passkey_reset_operation_admin_user_path(target),
             params: { reason: 'passkey recovery request', confirmation: 'RESET PASSKEYS' }
      end.to change(AuditLog, :count).by(1)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(target.passkeys.reload).to be_empty
        expect(audit_log).to have_attributes(
          action: 'admin.users.force_passkey_reset',
          outcome: 'succeeded',
          target_uid: "user:#{target.id}"
        )
        expect(audit_log.metadata).to include(
          'passkeys_count_before' => 1,
          'passkeys_count_after' => 0
        )
        expect(audit_log.attributes.to_json).not_to include(passkey.credential_id)
        expect(audit_log.attributes.to_json).not_to include(passkey.public_key)
        expect(audit_log.attributes.to_json).not_to include('challenge')
      end
    end

    it 'confirmation不一致はSystemOperationsで拒否し、passkeysを残す' do
      admin = create(:user, :admin)
      target = create(:user)
      create(:passkey, user: target)
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post force_passkey_reset_operation_admin_user_path(target),
             params: { reason: 'passkey recovery request', confirmation: 'WRONG' }
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(target.passkeys.reload.count).to eq(1)
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.force_passkey_reset',
          outcome: 'failed',
          error_code: 'confirmation_required'
        )
      end
    end

    it 'HTMLにcredential materialや開発者向け文言を出さない' do
      admin = create(:user, :admin)
      target = create(:user)
      passkey = create(:passkey, user: target, credential_id: 'credential-secret', public_key: 'PUBLIC KEY SECRET')
      sign_in admin
      stub_fresh_admin_reauthentication

      get admin_user_path(target)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('パスキーリセット')
        expect(response.body).to include(force_passkey_reset_operation_admin_user_path(target))
        expect(response.body).not_to include(passkey.credential_id)
        expect(response.body).not_to include(passkey.public_key)
        expect(response.body).not_to include('challenge')
        expect(response.body).not_to match(/v1\.0後|未実装|TODO|service\/facade|payload|development\/test|production/)
      end
    end
  end

  describe 'POST /admin/users/:id/operations/revoke_sessions' do
    it 'fresh reauthなしではSystemOperationsを呼ばずreauthへredirectする' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      allow(SystemOperations).to receive(:execute_user_operation)

      post revoke_sessions_operation_admin_user_path(target),
           params: { reason: 'device lost support request', confirmation: 'REVOKE SESSIONS' }

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

      post revoke_sessions_operation_admin_user_path(target),
           params: { reason: ' ', confirmation: 'REVOKE SESSIONS' }

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

      post revoke_sessions_operation_admin_user_path(target),
           params: { reason: 'device lost support request', confirmation: 'REVOKE SESSIONS' }

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(SystemOperations).to have_received(:execute_user_operation).with(
          operation: 'revoke_sessions',
          user: target,
          actor: admin,
          reason: 'device lost support request',
          request: kind_of(ActionDispatch::Request),
          reauthentication: hash_including(method: 'passkey', reauthenticated_at: kind_of(ActiveSupport::TimeWithZone)),
          confirmation: 'REVOKE SESSIONS'
        )
      end
    end

    it '実SystemOperations経由でsession_versionをincrementし、AuditLogを作成する' do
      admin = create(:user, :admin)
      target = create(:user, session_version: 2)
      user_session = UserSession.create!(
        user: target,
        session_uid_digest: SecureRandom.hex(32),
        session_version: 2,
        started_at: Time.current,
        last_seen_at: Time.current
      )
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post revoke_sessions_operation_admin_user_path(target),
             params: { reason: 'device lost support request', confirmation: 'REVOKE SESSIONS' }
      end.to change(AuditLog, :count).by(1)

      audit_log = AuditLog.last
      audit_payload = audit_log.attributes.to_json

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(target.reload.session_version).to eq(3)
        expect(audit_log).to have_attributes(
          action: 'admin.users.session_revoke',
          outcome: 'succeeded',
          target_uid: "user:#{target.id}"
        )
        expect(audit_log.before_state).to include('session_version' => 2)
        expect(audit_log.after_state).to include('session_version' => 3)
        expect(audit_log.metadata).to include('revoked_sessions_count' => 1)
        expect(user_session.reload.revoked_at).to be_present
        expect(UserSessions.active_for(user: target)).to be_empty
        expect(audit_payload).not_to include('session_id', 'cookie', 'remember_token')
        expect(audit_payload).not_to include('credential_id', 'public_key', 'challenge')
      end
    end

    it 'confirmation不一致はSystemOperationsで拒否し、session_versionを変更しない' do
      admin = create(:user, :admin)
      target = create(:user, session_version: 5)
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post revoke_sessions_operation_admin_user_path(target),
             params: { reason: 'device lost support request', confirmation: 'WRONG' }
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(target.reload.session_version).to eq(5)
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.session_revoke',
          outcome: 'failed',
          error_code: 'confirmation_required'
        )
      end
    end

    it 'HTMLにセッション失効フォームを表示し、秘匿情報や開発者向け文言を出さない' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      stub_fresh_admin_reauthentication

      get admin_user_path(target)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('セッション失効')
        expect(response.body).to include(revoke_sessions_operation_admin_user_path(target))
        expect(response.body).not_to include('session_id')
        expect(response.body).not_to include('remember_token')
        expect(response.body).not_to include('credential_id')
        expect(response.body).not_to include('public_key')
        expect(response.body).not_to include('challenge')
        expect(response.body).not_to match(/v1\.0後|未実装|TODO|service\/facade|payload|development\/test|production/)
      end
    end
  end

  describe 'POST /admin/users/:id/operations/delete' do
    it 'fresh reauthなしではSystemOperationsを呼ばずreauthへredirectする' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      allow(SystemOperations).to receive(:execute_user_operation)

      post delete_operation_admin_user_path(target),
           params: { reason: 'account deletion request', confirmation_email: target.email, confirmation: 'DELETE USER' }

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

      post delete_operation_admin_user_path(target),
           params: { reason: ' ', confirmation_email: target.email, confirmation: 'DELETE USER' }

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(SystemOperations).not_to have_received(:execute_user_operation)
        expect(User.where(id: target.id)).to exist
      end
    end

    it 'fresh reauth + reason + confirmationでSystemOperations経由で実行する' do
      admin = create(:user, :admin)
      target = create(:user, email: 'delete-request@example.com')
      sign_in admin
      stub_fresh_admin_reauthentication
      result = SystemOperations::Result.new(success: true)
      allow(SystemOperations).to receive(:execute_user_operation).and_return(result)

      post delete_operation_admin_user_path(target),
           params: { reason: 'account deletion request', confirmation_email: 'delete-request@example.com', confirmation: 'DELETE USER' }

      aggregate_failures do
        expect(response).to redirect_to(admin_users_path)
        expect(SystemOperations).to have_received(:execute_user_operation).with(
          operation: 'delete_user',
          user: target,
          actor: admin,
          reason: 'account deletion request',
          request: kind_of(ActionDispatch::Request),
          reauthentication: hash_including(method: 'passkey', reauthenticated_at: kind_of(ActiveSupport::TimeWithZone)),
          confirmation: hash_including(text: 'DELETE USER', email: 'delete-request@example.com')
        )
      end
    end

    it '実SystemOperations経由でuserを削除し、success後はusers indexへredirectする' do
      admin = create(:user, :admin)
      target = create(:user, email: 'delete-real@example.com')
      receipt = create(:receipt, :with_image, user: target)
      passkey = create(:passkey, user: target, credential_id: 'credential-secret-delete-request', public_key: 'PUBLIC KEY DELETE REQUEST')
      user_session = UserSession.create!(
        user: target,
        session_uid_digest: 'session-digest-secret-request',
        session_version: target.session_version,
        started_at: Time.current,
        last_seen_at: Time.current
      )
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post delete_operation_admin_user_path(target),
             params: { reason: 'account deletion request', confirmation_email: 'delete-real@example.com', confirmation: 'DELETE USER' }
      end.to change(AuditLog, :count).by(1)

      audit_log = AuditLog.last
      audit_payload = audit_log.attributes.to_json

      aggregate_failures do
        expect(response).to redirect_to(admin_users_path)
        expect(User.where(id: target.id)).not_to exist
        expect(Receipt.where(id: receipt.id)).not_to exist
        expect(Passkey.where(id: passkey.id)).not_to exist
        expect(UserSession.where(id: user_session.id)).not_to exist
        expect(audit_log).to have_attributes(
          actor_user: admin,
          action: 'admin.users.delete',
          outcome: 'succeeded',
          target_uid: "user:#{target.id}"
        )
        expect(audit_log.before_state).to include(
          'user_id' => target.id,
          'receipts_count' => 1,
          'passkeys_count' => 1,
          'user_sessions_count' => 1
        )
        expect(audit_log.after_state).to eq('deleted' => true)
        expect(audit_payload).not_to include('delete-real@example.com')
        expect(audit_payload).not_to include(passkey.credential_id, passkey.public_key, user_session.session_uid_digest)
        expect(audit_payload).not_to include('confirmation_token', 'unlock_token', 'challenge')
      end
    end

    it 'confirmation email不一致は削除せずfailed auditを残す' do
      admin = create(:user, :admin)
      target = create(:user, email: 'delete-mismatch@example.com')
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post delete_operation_admin_user_path(target),
             params: { reason: 'account deletion request', confirmation_email: 'wrong@example.com', confirmation: 'DELETE USER' }
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(User.where(id: target.id)).to exist
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.delete',
          outcome: 'failed',
          error_code: 'confirmation_email_required',
          target_uid: "user:#{target.id}"
        )
      end
    end

    it 'confirmation text不一致は削除せずfailed auditを残す' do
      admin = create(:user, :admin)
      target = create(:user, email: 'delete-text-mismatch@example.com')
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post delete_operation_admin_user_path(target),
             params: { reason: 'account deletion request', confirmation_email: target.email, confirmation: 'WRONG' }
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(User.where(id: target.id)).to exist
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.delete',
          outcome: 'failed',
          error_code: 'confirmation_required'
        )
      end
    end

    it 'HTMLに退会代行フォームを表示し、秘匿情報や開発者向け文言を出さない' do
      admin = create(:user, :admin)
      target = create(:user)
      passkey = create(:passkey, user: target, credential_id: 'credential-secret-delete-form', public_key: 'PUBLIC KEY DELETE FORM')
      sign_in admin
      stub_fresh_admin_reauthentication

      get admin_user_path(target)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('退会代行')
        expect(response.body).to include(delete_operation_admin_user_path(target))
        expect(response.body).to include('DELETE USER')
        expect(response.body).to include('surface-card-danger')
        expect(response.body).to include('person_off')
        expect(response.body).not_to include('token-border-danger')
        expect(response.body).not_to include('token-bg-danger-soft')
        expect(response.body).not_to include(passkey.credential_id)
        expect(response.body).not_to include(passkey.public_key)
        expect(response.body).not_to include('session_id')
        expect(response.body).not_to include('challenge')
        expect(response.body).not_to match(/v1\.0後|未実装|TODO|service\/facade|payload|development\/test|production/)
      end
    end
  end
end
