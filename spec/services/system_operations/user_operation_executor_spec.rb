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
      credential_id: 'credential-secret',
      public_key: 'public-key-secret',
      challenge: 'challenge-secret'
    }
  end

  around do |example|
    travel_to(Time.zone.parse('2026-05-27 10:00:00')) { example.run }
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

    it 'admin対象ユーザーへの操作を拒否する' do
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

    it 'unknown operationを拒否する' do
      result = described_class.call(
        operation: 'delete_user',
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
