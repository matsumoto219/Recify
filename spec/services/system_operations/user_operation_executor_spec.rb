require 'rails_helper'

RSpec.describe SystemOperations::UserOperationExecutor do
  include ActiveSupport::Testing::TimeHelpers

  let(:actor) { create(:user, :admin) }
  let(:target_user) { create(:user, failed_attempts: 2) }
  let(:request) { instance_double(ActionDispatch::Request, request_id: 'request-id', remote_ip: '127.0.0.1', user_agent: 'User Operation Spec') }
  let(:reauthenticated_at) { Time.current }
  let(:reauthentication) do
    {
      method: 'passkey',
      reauthenticated_at: reauthenticated_at,
      user_id: actor.id,
      session_version: actor.session_version,
      expires_at: reauthenticated_at + Admin.passkey_reauth_window_duration,
      credential_id: 'credential-secret',
      public_key: 'public-key-secret',
      challenge: 'challenge-secret'
    }
  end

  around do |example|
    travel_to(Time.zone.parse('2026-05-27 10:00:00')) { example.run }
  end

  before do
    ActionMailer::Base.deliveries.clear
  end

  after do
    ActionMailer::Base.deliveries.clear
  end

  describe '.call' do
    it 'lock_userで対象ユーザーをロックし、success auditを保存する' do
      result = described_class.call(
        operation: 'lock_user',
        user: target_user,
        actor: actor,
        reason: 'user support request',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'LOCK USER'
      )

      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_success
        expect(target_user.reload.locked_at).to be_present
        expect(audit_log).to have_attributes(
          actor_user: actor,
          actor_kind: 'admin',
          action: 'admin.users.lock',
          outcome: 'succeeded',
          target_type: 'User',
          target_id: target_user.id,
          target_uid: "user:#{target_user.id}",
          reason: 'user support request',
          request_id: 'request-id',
          user_agent: 'User Operation Spec'
        )
        expect(audit_log.metadata).to include(
          'operation' => 'lock_user',
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey',
          'reauthenticated_at' => reauthenticated_at.iso8601
        )
        expect(audit_log.before_state).to include(
          'user_id' => target_user.id,
          'locked' => false,
          'failed_attempts' => 2,
          'passkeys_count' => 0
        )
        expect(audit_log.after_state).to include(
          'user_id' => target_user.id,
          'locked' => true
        )
        expect(audit_log.attributes.to_json).not_to include('credential-secret', 'challenge-secret', 'public-key-secret')
        expect(audit_log.attributes.to_json).not_to include(target_user.encrypted_password)
        expect(audit_log.attributes.to_json).not_to include('unlock_token')
      end
    end

    it 'unlock_userで対象ユーザーのロックを解除し、failed attemptsをリセットする' do
      target_user.lock_access!(send_instructions: false)
      target_user.update!(failed_attempts: 7)

      result = described_class.call(
        operation: 'unlock_user',
        user: target_user,
        actor: actor,
        reason: 'unlock support request',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'UNLOCK USER'
      )

      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_success
        expect(target_user.reload.locked_at).to be_nil
        expect(target_user.failed_attempts).to eq(0)
        expect(audit_log.action).to eq('admin.users.unlock')
        expect(audit_log.before_state).to include('locked' => true, 'failed_attempts' => 7)
        expect(audit_log.after_state).to include('locked' => false, 'failed_attempts' => 0)
      end
    end

    it 'force_passkey_resetで対象ユーザーのpasskeysを削除し、credential情報なしでsuccess auditを保存する' do
      older = create(:passkey, user: target_user, credential_id: 'credential-secret-old', public_key: 'PUBLIC KEY OLD', last_used_at: 2.days.ago)
      latest = create(:passkey, user: target_user, credential_id: 'credential-secret-latest', public_key: 'PUBLIC KEY LATEST', last_used_at: 1.hour.ago)

      result = described_class.call(
        operation: 'force_passkey_reset',
        user: target_user,
        actor: actor,
        reason: 'passkey recovery request',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'RESET PASSKEYS'
      )

      audit_log = AuditLog.last
      audit_payload = audit_log.attributes.to_json

      aggregate_failures do
        expect(result).to be_success
        expect(target_user.passkeys.reload).to be_empty
        expect(audit_log).to have_attributes(
          actor_user: actor,
          action: 'admin.users.force_passkey_reset',
          outcome: 'succeeded',
          target_type: 'User',
          target_id: target_user.id,
          target_uid: "user:#{target_user.id}",
          reason: 'passkey recovery request'
        )
        expect(audit_log.metadata).to include(
          'operation' => 'force_passkey_reset',
          'passkeys_count_before' => 2,
          'passkeys_count_after' => 0,
          'latest_passkey_last_used_at' => latest.last_used_at.iso8601,
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey'
        )
        expect(audit_log.before_state).to include(
          'passkeys_count' => 2,
          'latest_passkey_last_used_at' => latest.last_used_at.iso8601
        )
        expect(audit_log.after_state).to include('passkeys_count' => 0)
        expect(audit_payload).not_to include(older.credential_id, latest.credential_id)
        expect(audit_payload).not_to include(older.public_key, latest.public_key)
        expect(audit_payload).not_to include('credential-secret', 'PUBLIC KEY', 'challenge-secret')
      end
    end

    it 'revoke_sessionsで対象ユーザーのsession_versionをincrementし、success auditを保存する' do
      target_user.update!(session_version: 4)
      target_user.remember_me!
      user_session = UserSession.create!(
        user: target_user,
        session_uid_digest: SecureRandom.hex(32),
        session_version: 4,
        started_at: Time.current,
        last_seen_at: Time.current
      )

      result = described_class.call(
        operation: 'revoke_sessions',
        user: target_user,
        actor: actor,
        reason: 'device lost support request',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'REVOKE SESSIONS'
      )

      audit_log = AuditLog.last
      audit_payload = audit_log.attributes.to_json

      aggregate_failures do
        expect(result).to be_success
        expect(target_user.reload.session_version).to eq(5)
        expect(target_user.remember_created_at).to be_nil
        expect(audit_log).to have_attributes(
          actor_user: actor,
          action: 'admin.users.session_revoke',
          outcome: 'succeeded',
          target_type: 'User',
          target_id: target_user.id,
          target_uid: "user:#{target_user.id}",
          reason: 'device lost support request'
        )
        expect(audit_log.metadata).to include(
          'operation' => 'revoke_sessions',
          'revoked_sessions_count' => 1,
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey',
          'reauthenticated_at' => reauthenticated_at.iso8601
        )
        expect(audit_log.before_state).to include('session_version' => 4)
        expect(audit_log.after_state).to include('session_version' => 5)
        expect(user_session.reload.revoked_at).to eq(Time.current)
        expect(UserSessions.active_for(user: target_user)).to be_empty
        expect(audit_payload).not_to include('session_id', 'session-secret', 'cookie', 'remember_token')
        expect(audit_payload).not_to include('credential-secret', 'challenge-secret', 'public-key-secret')
      end
    end

    it 'force_two_factor_resetでTOTP/recovery codesを削除し、sessionを失効してsuccess auditを保存する' do
      target_user.update!(session_version: 7)
      target_user.remember_me!
      totp = create(:totp_credential, user: target_user, totp_secret: 'TOTP-SECRET-VALUE')
      unused_code = create(:recovery_code, user: target_user, code_digest: 'code-digest-secret-unused')
      used_code = create(:recovery_code, user: target_user, code_digest: 'code-digest-secret-used', used_at: 1.day.ago)
      user_session = UserSession.create!(
        user: target_user,
        session_uid_digest: 'session-uid-digest-secret',
        session_version: 7,
        started_at: Time.current,
        last_seen_at: Time.current
      )

      result = described_class.call(
        operation: 'force_two_factor_reset',
        user: target_user,
        actor: actor,
        reason: 'all second factors lost',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'RESET 2FA'
      )

      audit_log = AuditLog.last
      audit_payload = audit_log.attributes.to_json

      aggregate_failures do
        expect(result).to be_success
        expect(target_user.reload.totp_credential).to be_nil
        expect(target_user.recovery_codes.reload).to be_empty
        expect(target_user.session_version).to eq(8)
        expect(target_user.remember_created_at).to be_nil
        expect(user_session.reload.revoked_at).to be_present
        expect(UserSessions.active_for(user: target_user)).to be_empty
        expect(audit_log).to have_attributes(
          actor_user: actor,
          action: 'admin.users.force_two_factor_reset',
          outcome: 'succeeded',
          target_type: 'User',
          target_id: target_user.id,
          target_uid: "user:#{target_user.id}",
          reason: 'all second factors lost'
        )
        expect(audit_log.metadata).to include(
          'operation' => 'force_two_factor_reset',
          'had_totp_before' => true,
          'had_totp_after' => false,
          'recovery_codes_count_before' => 2,
          'recovery_codes_count_after' => 0,
          'unused_recovery_codes_count_before' => 1,
          'unused_recovery_codes_count_after' => 0,
          'revoked_sessions_count' => 1,
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey'
        )
        expect(audit_log.before_state).to include(
          'totp_credential_present' => true,
          'totp_enabled' => true,
          'recovery_codes_count' => 2,
          'unused_recovery_codes_count' => 1,
          'session_version' => 7
        )
        expect(audit_log.after_state).to include(
          'totp_credential_present' => false,
          'totp_enabled' => false,
          'recovery_codes_count' => 0,
          'unused_recovery_codes_count' => 0,
          'session_version' => 8
        )
        expect(audit_payload).not_to include(totp.totp_secret)
        expect(audit_payload).not_to include(unused_code.code_digest, used_code.code_digest)
        expect(audit_payload).not_to include('session-uid-digest-secret')
        expect(audit_payload).not_to include('totp_secret', 'provisioning_uri', 'code_digest', 'cookie', 'token', 'secret')
      end
    end

    it 'force_password_reset_instructionでreset mailを送り、tokenやemail平文なしでsuccess auditを保存する' do
      previous_sent_at = 2.days.ago
      target_user.update!(reset_password_sent_at: previous_sent_at)

      result = nil
      expect do
        result = described_class.call(
          operation: 'force_password_reset_instruction',
          user: target_user,
          actor: actor,
          reason: 'password recovery support request',
          request: request,
          reauthentication: reauthentication,
          confirmation: 'SEND PASSWORD RESET'
        )
      end.to change(ActionMailer::Base.deliveries, :count).by(1)

      audit_log = AuditLog.last
      audit_payload = audit_log.attributes.to_json
      reset_mail = ActionMailer::Base.deliveries.last
      mail_body = [ reset_mail.text_part&.body&.decoded, reset_mail.html_part&.body&.decoded ].compact.join("\n")
      raw_token = mail_body[/reset_password_token=([^\s]+)/, 1]

      aggregate_failures do
        expect(result).to be_success
        expect(target_user.reload.reset_password_sent_at).to eq(Time.current)
        expect(target_user.reset_password_token).to be_present
        expect(audit_log).to have_attributes(
          actor_user: actor,
          action: 'admin.users.force_password_reset_instruction',
          outcome: 'succeeded',
          target_type: 'User',
          target_id: target_user.id,
          target_uid: "user:#{target_user.id}",
          reason: 'password recovery support request'
        )
        expect(audit_log.metadata).to include(
          'operation' => 'force_password_reset_instruction',
          'email_digest' => be_present,
          'reset_password_sent_at_before' => previous_sent_at.iso8601,
          'reset_password_sent_at_after' => Time.current.iso8601,
          'delivery_requested' => true,
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey'
        )
        expect(audit_log.after_state).to include('user_id' => target_user.id)
        expect(raw_token).to be_present
        expect(audit_payload).not_to include(raw_token)
        expect(audit_payload).not_to include(target_user.email)
        expect(audit_payload).not_to include('reset_password_token', 'reset_password_url', '/users/password')
        expect(audit_payload).not_to include('cookie-secret', 'session-uid-secret')
      end
    end

    it 'admin_email_change_recoveryでunconfirmed_emailだけを設定し、sessionを失効してsuccess auditを保存する' do
      old_email = target_user.email
      target_user.remember_me!
      user_session = UserSession.create!(
        user: target_user,
        session_uid_digest: 'email-change-session-digest-secret',
        session_version: target_user.session_version,
        started_at: Time.current,
        last_seen_at: Time.current
      )
      new_email = 'recovery-change@example.com'

      result = nil
      expect do
        result = described_class.call(
          operation: 'admin_email_change_recovery',
          user: target_user,
          actor: actor,
          reason: 'verified account recovery request',
          request: request,
          reauthentication: reauthentication,
          confirmation: { text: 'CHANGE RECOVERY EMAIL', new_email: new_email }
        )
      end.to change(ActionMailer::Base.deliveries, :count).by(2)

      audit_log = AuditLog.last
      audit_payload = audit_log.attributes.to_json
      delivered_recipients = ActionMailer::Base.deliveries.flat_map(&:to)
      confirmation_mail = ActionMailer::Base.deliveries.find { |mail| mail.to.include?(new_email) }
      confirmation_body = [ confirmation_mail.text_part&.body&.decoded, confirmation_mail.html_part&.body&.decoded ].compact.join("\n")
      confirmation_token = confirmation_body[/confirmation_token=([^\s]+)/, 1]

      aggregate_failures do
        expect(result).to be_success
        expect(target_user.reload.email).to eq(old_email)
        expect(target_user.unconfirmed_email).to eq(new_email)
        expect(target_user.session_version).to eq(1)
        expect(target_user.remember_created_at).to be_nil
        expect(user_session.reload.revoked_at).to be_present
        expect(delivered_recipients).to include(new_email, old_email)
        expect(audit_log).to have_attributes(
          actor_user: actor,
          action: 'admin.users.account_recovery_email_change',
          outcome: 'succeeded',
          target_type: 'User',
          target_id: target_user.id,
          target_uid: "user:#{target_user.id}",
          reason: 'verified account recovery request'
        )
        expect(audit_log.metadata).to include(
          'operation' => 'admin_email_change_recovery',
          'old_email_digest' => be_present,
          'new_email_digest' => be_present,
          'unconfirmed_email_digest' => be_present,
          'session_version_before' => 0,
          'session_version_after' => 1,
          'revoked_sessions_count' => 1,
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey'
        )
        expect(confirmation_token).to be_present
        expect(audit_payload).not_to include(old_email, new_email, confirmation_token)
        expect(audit_payload).not_to include('confirmation_token', 'email-change-session-digest-secret')
      end
    end

    it 'delete_userで対象ユーザーを削除し、target_uidで追跡できるsuccess auditを保存する' do
      receipt = create(:receipt, :with_image, user: target_user)
      owned_run = create(:receipt_analysis_run, :succeeded, receipt: receipt)
      passkey = create(:passkey, user: target_user, credential_id: 'credential-secret-delete', public_key: 'PUBLIC KEY DELETE')
      user_session = UserSession.create!(
        user: target_user,
        session_uid_digest: 'session-digest-secret',
        session_version: target_user.session_version,
        started_at: Time.current,
        last_seen_at: Time.current
      )
      create(:notification, user: target_user)
      other_user = create(:user)
      external_receipt = create(:receipt, user: other_user)
      requested_run = create(:receipt_analysis_run, :admin_retry, receipt: external_receipt, requested_by_user: target_user)
      avatar_attachment_id = nil
      target_user.avatar.attach(
        io: File.open(Rails.root.join('spec/fixtures/files/receipt_sample.jpg')),
        filename: 'avatar.jpg',
        content_type: 'image/jpeg'
      )
      avatar_attachment_id = target_user.avatar.attachment.id
      receipt_image_attachment_id = receipt.image.attachment.id

      result = described_class.call(
        operation: 'delete_user',
        user: target_user,
        actor: actor,
        reason: 'confirmed account deletion request',
        request: request,
        reauthentication: reauthentication,
        confirmation: { email: target_user.email, text: 'DELETE USER' }
      )

      audit_log = AuditLog.last
      audit_payload = audit_log.attributes.to_json

      aggregate_failures do
        expect(result).to be_success
        expect(User.where(id: target_user.id)).not_to exist
        expect(Receipt.where(id: receipt.id)).not_to exist
        expect(ReceiptAnalysisRun.where(id: owned_run.id)).not_to exist
        expect(Passkey.where(id: passkey.id)).not_to exist
        expect(UserSession.where(id: user_session.id)).not_to exist
        expect(requested_run.reload.requested_by_user_id).to be_nil
        expect(ActiveStorage::Attachment.where(id: avatar_attachment_id)).not_to exist
        expect(ActiveStorage::Attachment.where(id: receipt_image_attachment_id)).not_to exist
        expect(audit_log).to have_attributes(
          actor_user: actor,
          action: 'admin.users.delete',
          outcome: 'succeeded',
          target_type: 'User',
          target_id: target_user.id,
          target_uid: "user:#{target_user.id}",
          reason: 'confirmed account deletion request'
        )
        expect(audit_log.metadata).to include(
          'operation' => 'delete_user',
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey',
          'reauthenticated_at' => reauthenticated_at.iso8601
        )
        expect(audit_log.before_state).to include(
          'user_id' => target_user.id,
          'email_digest' => be_present,
          'admin' => false,
          'guest' => false,
          'receipts_count' => 1,
          'passkeys_count' => 1,
          'user_sessions_count' => 1,
          'notifications_count' => 1,
          'avatar_attached' => true
        )
        expect(audit_log.after_state).to eq('deleted' => true)
        expect(audit_payload).not_to include(target_user.email)
        expect(audit_payload).not_to include(target_user.encrypted_password)
        expect(audit_payload).not_to include(passkey.credential_id, passkey.public_key)
        expect(audit_payload).not_to include(user_session.session_uid_digest)
        expect(audit_payload).not_to include('confirmation_token', 'unlock_token', 'challenge-secret')
      end
    end

    it 'delete_userのconfirmation email不一致を拒否し、failed auditを残す' do
      result = described_class.call(
        operation: 'delete_user',
        user: target_user,
        actor: actor,
        reason: 'confirmed account deletion request',
        request: request,
        reauthentication: reauthentication,
        confirmation: { email: 'wrong@example.com', text: 'DELETE USER' }
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('confirmation_email_required')
        expect(User.where(id: target_user.id)).to exist
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.delete',
          outcome: 'failed',
          error_code: 'confirmation_email_required',
          target_uid: "user:#{target_user.id}"
        )
      end
    end

    it 'delete_userのconfirmation text不一致を拒否する' do
      result = described_class.call(
        operation: 'delete_user',
        user: target_user,
        actor: actor,
        reason: 'confirmed account deletion request',
        request: request,
        reauthentication: reauthentication,
        confirmation: { email: target_user.email, text: 'WRONG' }
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('confirmation_required')
        expect(User.where(id: target_user.id)).to exist
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.delete',
          outcome: 'failed',
          error_code: 'confirmation_required'
        )
      end
    end

    it '自分自身へのdelete_userを拒否する' do
      result = described_class.call(
        operation: 'delete_user',
        user: actor,
        actor: actor,
        reason: 'self delete',
        request: request,
        reauthentication: reauthentication,
        confirmation: { email: actor.email, text: 'DELETE USER' }
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('self_operation_forbidden')
        expect(User.where(id: actor.id)).to exist
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.delete',
          outcome: 'failed',
          error_code: 'self_operation_forbidden'
        )
      end
    end

    it 'admin対象ユーザーへのdelete_userを拒否する' do
      admin_target = create(:user, :admin, email: 'admin-target-delete@example.com')

      result = described_class.call(
        operation: 'delete_user',
        user: admin_target,
        actor: actor,
        reason: 'admin target delete',
        request: request,
        reauthentication: reauthentication,
        confirmation: { email: admin_target.email, text: 'DELETE USER' }
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('admin_target_forbidden')
        expect(User.where(id: admin_target.id)).to exist
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.delete',
          outcome: 'failed',
          error_code: 'admin_target_forbidden'
        )
      end
    end

    it 'delete_userのsuccess AuditLog作成に失敗した場合はuserを削除しない' do
      allow(AuditLogs).to receive(:record_admin_action!).and_wrap_original do |method, **kwargs|
        if kwargs[:action] == 'admin.users.delete' && kwargs[:outcome] == 'succeeded'
          raise ActiveRecord::RecordInvalid.new(AuditLog.new)
        end

        method.call(**kwargs)
      end

      result = described_class.call(
        operation: 'delete_user',
        user: target_user,
        actor: actor,
        reason: 'confirmed account deletion request',
        request: request,
        reauthentication: reauthentication,
        confirmation: { email: target_user.email, text: 'DELETE USER' }
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('user_operation_failed')
        expect(User.where(id: target_user.id)).to exist
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.delete',
          outcome: 'failed',
          error_code: 'user_operation_failed',
          target_uid: "user:#{target_user.id}"
        )
      end
    end

    it 'delete_userのdestroy失敗時はfailed auditを残してuserを残す' do
      allow(Users).to receive(:delete_account).and_raise(ActiveRecord::RecordNotDestroyed.new('blocked', target_user))

      result = described_class.call(
        operation: 'delete_user',
        user: target_user,
        actor: actor,
        reason: 'confirmed account deletion request',
        request: request,
        reauthentication: reauthentication,
        confirmation: { email: target_user.email, text: 'DELETE USER' }
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('user_operation_failed')
        expect(User.where(id: target_user.id)).to exist
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.delete',
          outcome: 'failed',
          error_code: 'user_operation_failed',
          target_uid: "user:#{target_user.id}"
        )
      end
    end

    it 'already locked userのlock_userは失敗auditを残す' do
      target_user.lock_access!(send_instructions: false)

      result = described_class.call(
        operation: 'lock_user',
        user: target_user,
        actor: actor,
        reason: 'duplicate lock',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'LOCK USER'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('target_already_locked')
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.lock',
          outcome: 'failed',
          error_code: 'target_already_locked'
        )
      end
    end

    it 'unlocked userのunlock_userは失敗auditを残す' do
      result = described_class.call(
        operation: 'unlock_user',
        user: target_user,
        actor: actor,
        reason: 'duplicate unlock',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'UNLOCK USER'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('target_not_locked')
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.unlock',
          outcome: 'failed',
          error_code: 'target_not_locked'
        )
      end
    end

    it 'passkeys 0件のforce_passkey_resetは失敗auditを残す' do
      result = described_class.call(
        operation: 'force_passkey_reset',
        user: target_user,
        actor: actor,
        reason: 'passkey recovery request',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'RESET PASSKEYS'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('passkeys_missing')
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.force_passkey_reset',
          outcome: 'failed',
          error_code: 'passkeys_missing',
          target_uid: "user:#{target_user.id}"
        )
      end
    end

    it 'TOTP/recovery codes 0件のforce_two_factor_resetは失敗auditを残す' do
      result = described_class.call(
        operation: 'force_two_factor_reset',
        user: target_user,
        actor: actor,
        reason: 'all second factors lost',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'RESET 2FA'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('two_factor_missing')
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.force_two_factor_reset',
          outcome: 'failed',
          error_code: 'two_factor_missing',
          target_uid: "user:#{target_user.id}"
        )
      end
    end

    it 'guest対象ユーザーへのforce_password_reset_instructionを拒否する' do
      guest = User.guest!

      result = described_class.call(
        operation: 'force_password_reset_instruction',
        user: guest,
        actor: actor,
        reason: 'password recovery support request',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'SEND PASSWORD RESET'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('guest_target_forbidden')
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(guest.reload.reset_password_sent_at).to be_nil
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.force_password_reset_instruction',
          outcome: 'failed',
          error_code: 'guest_target_forbidden'
        )
      end
    end

    it 'unconfirmed対象ユーザーへのforce_password_reset_instructionを拒否する' do
      unconfirmed_user = create(:user, :unconfirmed)
      ActionMailer::Base.deliveries.clear

      result = described_class.call(
        operation: 'force_password_reset_instruction',
        user: unconfirmed_user,
        actor: actor,
        reason: 'password recovery support request',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'SEND PASSWORD RESET'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('unconfirmed_target_forbidden')
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(unconfirmed_user.reload.reset_password_sent_at).to be_nil
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.force_password_reset_instruction',
          outcome: 'failed',
          error_code: 'unconfirmed_target_forbidden'
        )
      end
    end

    it 'admin_email_change_recoveryのnew email blankを拒否する' do
      result = described_class.call(
        operation: 'admin_email_change_recovery',
        user: target_user,
        actor: actor,
        reason: 'verified account recovery request',
        request: request,
        reauthentication: reauthentication,
        confirmation: { text: 'CHANGE RECOVERY EMAIL', new_email: ' ' }
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('recovery_email_required')
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(target_user.reload.unconfirmed_email).to be_nil
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.account_recovery_email_change',
          outcome: 'failed',
          error_code: 'recovery_email_required'
        )
      end
    end

    it 'admin_email_change_recoveryのduplicate emailを拒否する' do
      existing = create(:user, email: 'existing-recovery@example.com')

      result = described_class.call(
        operation: 'admin_email_change_recovery',
        user: target_user,
        actor: actor,
        reason: 'verified account recovery request',
        request: request,
        reauthentication: reauthentication,
        confirmation: { text: 'CHANGE RECOVERY EMAIL', new_email: existing.email }
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('recovery_email_taken')
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(target_user.reload.unconfirmed_email).to be_nil
        expect(AuditLog.last.error_code).to eq('recovery_email_taken')
      end
    end

    it 'admin_email_change_recoveryのconfirmation不一致を拒否する' do
      result = described_class.call(
        operation: 'admin_email_change_recovery',
        user: target_user,
        actor: actor,
        reason: 'verified account recovery request',
        request: request,
        reauthentication: reauthentication,
        confirmation: { text: 'WRONG', new_email: 'recovery-change@example.com' }
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('confirmation_required')
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(target_user.reload.unconfirmed_email).to be_nil
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.account_recovery_email_change',
          outcome: 'failed',
          error_code: 'confirmation_required'
        )
      end
    end

    it 'locked userへのforce_password_reset_instructionはunlockしない' do
      target_user.lock_access!(send_instructions: false)
      locked_at = target_user.locked_at

      result = described_class.call(
        operation: 'force_password_reset_instruction',
        user: target_user,
        actor: actor,
        reason: 'password recovery support request',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'SEND PASSWORD RESET'
      )

      aggregate_failures do
        expect(result).to be_success
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(target_user.reload.locked_at).to eq(locked_at)
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.force_password_reset_instruction',
          outcome: 'succeeded'
        )
      end
    end

    it '自分自身へのlock_userを拒否する' do
      result = described_class.call(
        operation: 'lock_user',
        user: actor,
        actor: actor,
        reason: 'self lock',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'LOCK USER'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('self_operation_forbidden')
        expect(actor.reload.locked_at).to be_nil
        expect(AuditLog.last.error_code).to eq('self_operation_forbidden')
      end
    end

    it '自分自身へのforce_passkey_resetを拒否する' do
      create(:passkey, user: actor)

      result = described_class.call(
        operation: 'force_passkey_reset',
        user: actor,
        actor: actor,
        reason: 'self reset',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'RESET PASSKEYS'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('self_operation_forbidden')
        expect(actor.passkeys.reload.count).to eq(1)
        expect(AuditLog.last.error_code).to eq('self_operation_forbidden')
      end
    end

    it '自分自身へのforce_two_factor_resetを拒否する' do
      create(:totp_credential, user: actor)

      result = described_class.call(
        operation: 'force_two_factor_reset',
        user: actor,
        actor: actor,
        reason: 'self reset',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'RESET 2FA'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('self_operation_forbidden')
        expect(actor.reload.totp_credential).to be_present
        expect(AuditLog.last.error_code).to eq('self_operation_forbidden')
      end
    end

    it '自分自身へのforce_password_reset_instructionを拒否する' do
      result = described_class.call(
        operation: 'force_password_reset_instruction',
        user: actor,
        actor: actor,
        reason: 'self reset',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'SEND PASSWORD RESET'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('self_operation_forbidden')
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(actor.reload.reset_password_sent_at).to be_nil
        expect(AuditLog.last.error_code).to eq('self_operation_forbidden')
      end
    end

    it '自分自身へのadmin_email_change_recoveryを拒否する' do
      result = described_class.call(
        operation: 'admin_email_change_recovery',
        user: actor,
        actor: actor,
        reason: 'self email recovery',
        request: request,
        reauthentication: reauthentication,
        confirmation: { text: 'CHANGE RECOVERY EMAIL', new_email: 'self-recovery@example.com' }
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('self_operation_forbidden')
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(actor.reload.unconfirmed_email).to be_nil
        expect(AuditLog.last.error_code).to eq('self_operation_forbidden')
      end
    end

    it '自分自身へのrevoke_sessionsを拒否する' do
      actor.update!(session_version: 3)

      result = described_class.call(
        operation: 'revoke_sessions',
        user: actor,
        actor: actor,
        reason: 'self revoke',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'REVOKE SESSIONS'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('self_operation_forbidden')
        expect(actor.reload.session_version).to eq(3)
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.session_revoke',
          outcome: 'failed',
          error_code: 'self_operation_forbidden'
        )
      end
    end

    it 'admin対象ユーザーへのforce_passkey_resetを拒否する' do
      admin_target = create(:user, :admin)
      create(:passkey, user: admin_target)

      result = described_class.call(
        operation: 'force_passkey_reset',
        user: admin_target,
        actor: actor,
        reason: 'admin target',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'RESET PASSKEYS'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('admin_target_forbidden')
        expect(admin_target.passkeys.reload.count).to eq(1)
        expect(AuditLog.last.error_code).to eq('admin_target_forbidden')
      end
    end

    it 'admin対象ユーザーへのforce_two_factor_resetを拒否する' do
      admin_target = create(:user, :admin)
      create(:totp_credential, user: admin_target)

      result = described_class.call(
        operation: 'force_two_factor_reset',
        user: admin_target,
        actor: actor,
        reason: 'admin target',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'RESET 2FA'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('admin_target_forbidden')
        expect(admin_target.reload.totp_credential).to be_present
        expect(AuditLog.last.error_code).to eq('admin_target_forbidden')
      end
    end

    it 'admin対象ユーザーへのforce_password_reset_instructionを拒否する' do
      admin_target = create(:user, :admin)

      result = described_class.call(
        operation: 'force_password_reset_instruction',
        user: admin_target,
        actor: actor,
        reason: 'admin target',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'SEND PASSWORD RESET'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('admin_target_forbidden')
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(admin_target.reload.reset_password_sent_at).to be_nil
        expect(AuditLog.last.error_code).to eq('admin_target_forbidden')
      end
    end

    it 'admin対象ユーザーへのadmin_email_change_recoveryを拒否する' do
      admin_target = create(:user, :admin)

      result = described_class.call(
        operation: 'admin_email_change_recovery',
        user: admin_target,
        actor: actor,
        reason: 'admin target',
        request: request,
        reauthentication: reauthentication,
        confirmation: { text: 'CHANGE RECOVERY EMAIL', new_email: 'admin-recovery@example.com' }
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('admin_target_forbidden')
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(admin_target.reload.unconfirmed_email).to be_nil
        expect(AuditLog.last.error_code).to eq('admin_target_forbidden')
      end
    end

    it 'admin対象ユーザーへのrevoke_sessionsを拒否する' do
      admin_target = create(:user, :admin)
      admin_target.update!(session_version: 9)

      result = described_class.call(
        operation: 'revoke_sessions',
        user: admin_target,
        actor: actor,
        reason: 'admin target',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'REVOKE SESSIONS'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('admin_target_forbidden')
        expect(admin_target.reload.session_version).to eq(9)
        expect(AuditLog.last.error_code).to eq('admin_target_forbidden')
      end
    end

    it 'reason / reauthentication / confirmationを必須にする' do
      blank_reason = described_class.call(
        operation: 'lock_user',
        user: target_user,
        actor: actor,
        reason: ' ',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'LOCK USER'
      )
      missing_reauth = described_class.call(
        operation: 'lock_user',
        user: target_user,
        actor: actor,
        reason: 'support request',
        request: request,
        reauthentication: nil,
        confirmation: 'LOCK USER'
      )
      wrong_confirmation = described_class.call(
        operation: 'force_passkey_reset',
        user: target_user,
        actor: actor,
        reason: 'support request',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'WRONG'
      )

      aggregate_failures do
        expect(blank_reason.error_code).to eq('reason_required')
        expect(missing_reauth.error_code).to eq('reauthentication_required')
        expect(wrong_confirmation.error_code).to eq('confirmation_required')
        expect(target_user.reload.locked_at).to be_nil
      end
    end

    it 'TOTP/recovery codeのreauthentication contextでは高リスク操作を許可しない' do
      %w[totp recovery_code].each do |method|
        result = described_class.call(
          operation: 'lock_user',
          user: target_user,
          actor: actor,
          reason: 'support request',
          request: request,
          reauthentication: { method: method, reauthenticated_at: Time.current },
          confirmation: 'LOCK USER'
        )

        aggregate_failures method do
          expect(result).to be_failure
          expect(result.error_code).to eq('reauthentication_required')
          expect(target_user.reload.locked_at).to be_nil
          expect(AuditLog.last).to have_attributes(
            action: 'admin.users.lock',
            outcome: 'failed',
            error_code: 'reauthentication_required'
          )
        end
      end
    end

    it 'unknown operationを拒否する' do
      result = described_class.call(
        operation: 'delete_everything',
        user: target_user,
        actor: actor,
        reason: 'bad operation',
        request: request,
        reauthentication: reauthentication,
        confirmation: 'DELETE USER'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('unknown_operation')
        expect(AuditLog.last).to have_attributes(
          action: 'admin.users.unknown_operation',
          outcome: 'failed',
          error_code: 'unknown_operation'
        )
      end
    end
  end
end
