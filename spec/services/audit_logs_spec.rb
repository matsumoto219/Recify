require 'rails_helper'

RSpec.describe AuditLogs do
  describe '.record_admin_action!' do
    it 'admin actionをrequest context付きで記録する' do
      actor = create(:user, :admin)
      receipt = create(:receipt)
      request = instance_double(
        ActionDispatch::Request,
        request_id: 'req-123',
        remote_ip: '203.0.113.20',
        user_agent: 'RSpec Browser'
      )

      log = described_class.record_admin_action!(
        actor: actor,
        action: 'receipt_analysis.full_reanalyze',
        target: receipt,
        target_uid: receipt.public_id,
        reason: '問い合わせ対応',
        outcome: 'succeeded',
        metadata: { retry_type: :full_reanalyze },
        before_state: { status: 'failed' },
        after_state: { status: 'processing' },
        request: request
      )

      expect(log).to have_attributes(
        actor_user: actor,
        actor_kind: 'admin',
        action: 'receipt_analysis.full_reanalyze',
        target_type: 'Receipt',
        target_id: receipt.id,
        target_uid: receipt.public_id,
        reason: '問い合わせ対応',
        outcome: 'succeeded',
        request_id: 'req-123',
        user_agent: 'RSpec Browser'
      )
      expect(log.ip_address.to_s).to eq('203.0.113.20')
      expect(log.metadata).to eq('retry_type' => 'full_reanalyze')
      expect(log.before_state).to eq('status' => 'failed')
      expect(log.after_state).to eq('status' => 'processing')
    end

    it 'full request bodyを保存しない' do
      actor = create(:user, :admin)
      request = instance_double(
        ActionDispatch::Request,
        request_id: 'req-456',
        remote_ip: '203.0.113.21',
        user_agent: 'RSpec Browser',
        raw_post: 'password=secret'
      )

      log = described_class.record_admin_action!(
        actor: actor,
        action: 'receipt_analysis.ai_retry',
        outcome: 'succeeded',
        metadata: { retry_type: 'ai_retry' },
        request: request
      )

      expect(log.attributes.values.join("\n")).not_to include('password=secret')
      expect(log.metadata).to eq('retry_type' => 'ai_retry')
    end
  end

  describe '.record_system_action!' do
    it 'system actionを記録する' do
      log = described_class.record_system_action!(
        action: 'receipt_analysis.stale_cleanup',
        reason: 'hourly cleanup',
        outcome: 'succeeded',
        metadata: { dry_run: true, stale_count: 2 }
      )

      expect(log).to have_attributes(
        actor_user: nil,
        actor_kind: 'system',
        action: 'receipt_analysis.stale_cleanup',
        reason: 'hourly cleanup',
        outcome: 'succeeded'
      )
      expect(log.metadata).to eq('dry_run' => true, 'stale_count' => 2)
    end
  end

  describe '.sanitize' do
    it 'metadata / before_state / after_stateからraw・prompt・secret系キーを再帰的に除外する' do
      log = described_class.record_system_action!(
        action: 'receipt_analysis.finalize_retry',
        outcome: 'failed',
        error_code: 'retry_failed',
        metadata: {
          safe: 'visible',
          raw_text: 'ocr raw',
          prompt: 'full prompt',
          code_digest: 'digest-secret',
          nested: {
            messages: [ { role: 'user', content: 'secret prompt' } ],
            result: 'ok',
            code_digest: 'nested-digest-secret',
            api_key: 'sk-test'
          },
          array: [
            { token: 'hidden', code_digest: 'array-digest-secret', value: 'kept' },
            { authorization_header: 'Bearer secret', value: 'also kept' }
          ]
        },
        before_state: { password: 'hidden', code_digest: 'before-digest-secret', status: 'failed' },
        after_state: { session: 'hidden', code_digest: 'after-digest-secret', status: 'processing' }
      )

      expect(log.metadata).to eq(
        'safe' => 'visible',
        'nested' => { 'result' => 'ok' },
        'array' => [
          { 'value' => 'kept' },
          { 'value' => 'also kept' }
        ]
      )
      expect(log.before_state).to eq('status' => 'failed')
      expect(log.after_state).to eq('status' => 'processing')
      expect(log.metadata.to_json).not_to include('ocr raw', 'full prompt', 'sk-test', 'Bearer secret', 'digest-secret')
    end

    it '長い文字列と配列を上限内に丸める' do
      long_text = 'a' * (described_class::MAX_STRING_BYTES + 50)
      values = Array.new(described_class::MAX_ARRAY_ITEMS + 5) { |index| { value: index } }

      log = described_class.record_system_action!(
        action: 'receipt_analysis.debug',
        outcome: 'succeeded',
        metadata: { long_text: long_text, values: values }
      )

      expect(log.metadata['long_text'].bytesize).to be <= described_class::MAX_STRING_BYTES
      expect(log.metadata['values'].size).to eq(described_class::MAX_ARRAY_ITEMS)
    end

    it 'passkey credential materialを保存しない' do
      log = described_class.record_admin_action!(
        actor: create(:user, :admin),
        action: 'admin.passkey_reauthentication',
        outcome: 'succeeded',
        metadata: {
          reauthenticated: true,
          method: 'passkey',
          credential_id: 'credential-secret',
          public_key: 'public-key-secret',
          challenge: 'challenge-secret',
          authenticator_data: 'authenticator-data-secret',
          client_data_json: 'client-data-json-secret',
          attestation_object: 'attestation-object-secret',
          raw_id: 'raw-id-secret',
          signature: 'signature-secret',
          user_handle: 'user-handle-secret',
          nested: {
            passkey_public_key: 'nested-public-key-secret',
            safe: 'visible'
          }
        }
      )

      expect(log.metadata).to eq(
        'reauthenticated' => true,
        'method' => 'passkey',
        'nested' => { 'safe' => 'visible' }
      )
      expect(log.metadata.to_json).not_to include(
        'credential-secret',
        'public-key-secret',
        'challenge-secret',
        'authenticator-data-secret',
        'client-data-json-secret',
        'attestation-object-secret',
        'raw-id-secret',
        'signature-secret',
        'user-handle-secret',
        'nested-public-key-secret'
      )
    end

    it 'session本体は保存せずsession_versionだけを状態値として残す' do
      log = described_class.record_admin_action!(
        actor: create(:user, :admin),
        action: 'admin.users.session_revoke',
        outcome: 'succeeded',
        metadata: { revoked_sessions_count: 2, session_id: 'session-id-secret' },
        before_state: {
          session_version: 3,
          session: 'session-secret',
          cookie: 'cookie-secret',
          remember_token: 'remember-secret'
        },
        after_state: { session_version: 4 }
      )

      aggregate_failures do
        expect(log.metadata).to eq('revoked_sessions_count' => 2)
        expect(log.before_state).to eq('session_version' => 3)
        expect(log.after_state).to eq('session_version' => 4)
        expect(log.attributes.to_json).not_to include('session-id-secret', 'session-secret', 'cookie-secret', 'remember-secret')
      end
    end

    it 'password reset instructionのsafe metadataだけを残し、tokenやURLを保存しない' do
      reset_sent_at_before = 1.day.ago
      reset_sent_at_after = Time.current

      log = described_class.record_admin_action!(
        actor: create(:user, :admin),
        action: 'admin.users.force_password_reset_instruction',
        outcome: 'succeeded',
        metadata: {
          operation: 'force_password_reset_instruction',
          email_digest: 'safe-email-digest',
          reset_password_sent_at_before: reset_sent_at_before,
          reset_password_sent_at_after: reset_sent_at_after,
          delivery_requested: true,
          reset_password_token: 'raw-reset-token-secret',
          reset_password_url: 'https://example.com/users/password/edit?reset_password_token=raw-reset-token-secret'
        }
      )

      aggregate_failures do
        expect(log.metadata).to eq(
          'operation' => 'force_password_reset_instruction',
          'email_digest' => 'safe-email-digest',
          'reset_password_sent_at_before' => reset_sent_at_before.iso8601,
          'reset_password_sent_at_after' => reset_sent_at_after.iso8601,
          'delivery_requested' => true
        )
        expect(log.attributes.to_json).not_to include('raw-reset-token-secret', '/users/password/edit')
      end
    end

    it 'account recovery email changeのdigest metadataだけを残し、メール平文を保存しない' do
      log = described_class.record_admin_action!(
        actor: create(:user, :admin),
        action: 'admin.users.account_recovery_email_change',
        outcome: 'succeeded',
        metadata: {
          operation: 'admin_email_change_recovery',
          old_email_digest: 'old-safe-digest',
          new_email_digest: 'new-safe-digest',
          unconfirmed_email_digest: 'unconfirmed-safe-digest',
          session_version_before: 2,
          session_version_after: 3,
          revoked_sessions_count: 1
        }
      )

      expect(log.metadata).to eq(
        'operation' => 'admin_email_change_recovery',
        'old_email_digest' => 'old-safe-digest',
        'new_email_digest' => 'new-safe-digest',
        'unconfirmed_email_digest' => 'unconfirmed-safe-digest',
        'session_version_before' => 2,
        'session_version_after' => 3,
        'revoked_sessions_count' => 1
      )
    end

    it 'TOTP secret / code / recovery code materialを保存しない' do
      log = described_class.record_admin_action!(
        actor: create(:user, :admin),
        action: 'user.two_factor.totp.enabled',
        outcome: 'succeeded',
        metadata: {
          id: 'ordinary-id',
          had_totp_before: true,
          had_totp_after: false,
          recovery_codes_count: 10,
          recovery_codes_count_before: 10,
          recovery_codes_count_after: 0,
          unused_recovery_codes_count: 7,
          unused_recovery_codes_count_before: 7,
          unused_recovery_codes_count_after: 0,
          backup_codes_count: 10,
          code_digest: 'recovery-code-digest-secret',
          totp: '123456',
          otp: '654321',
          otp_attempt: '123456',
          totp_code: '123456',
          totp_secret: 'totp-secret',
          encrypted_totp_secret: 'encrypted-totp-secret',
          recovery_code: 'recovery-secret',
          recovery_codes: [ 'recovery-secret-1', 'recovery-secret-2' ],
          backup_code: 'backup-secret',
          backup_codes: [ 'backup-secret' ],
          provisioning_uri: 'otpauth://totp/Recify',
          otpauth: 'otpauth://totp/Recify',
          two_factor: { enabled: true, totp_secret: 'nested-totp-secret' },
          second_factor: { recovery_code: 'nested-recovery-secret' },
          one_time_password: '999999',
          nested: {
            safe: 'visible',
            code_digest: 'nested-code-digest-secret',
            account_recovery_code: 'nested-fragment-secret'
          }
        },
        before_state: {
          totp_enabled: false,
          recovery_codes_count: 0,
          code_digest: 'before-code-digest-secret',
          id: 'safe-id'
        },
        after_state: {
          totp_enabled: true,
          code_digest: 'after-code-digest-secret',
          recovery_codes_count: 10
        }
      )

      aggregate_failures do
        expect(log.metadata).to eq(
          'id' => 'ordinary-id',
          'had_totp_before' => true,
          'had_totp_after' => false,
          'recovery_codes_count' => 10,
          'recovery_codes_count_before' => 10,
          'recovery_codes_count_after' => 0,
          'unused_recovery_codes_count' => 7,
          'unused_recovery_codes_count_before' => 7,
          'unused_recovery_codes_count_after' => 0,
          'backup_codes_count' => 10,
          'nested' => { 'safe' => 'visible' }
        )
        expect(log.before_state).to eq('totp_enabled' => false, 'recovery_codes_count' => 0, 'id' => 'safe-id')
        expect(log.after_state).to eq('totp_enabled' => true, 'recovery_codes_count' => 10)
        expect(log.attributes.to_json).not_to include(
          '123456',
          '654321',
          'totp-secret',
          'encrypted-totp-secret',
          'recovery-secret',
          'backup-secret',
          'recovery-code-digest-secret',
          'nested-code-digest-secret',
          'before-code-digest-secret',
          'after-code-digest-secret',
          'otpauth://totp/Recify',
          'nested-totp-secret',
          'nested-recovery-secret',
          'nested-fragment-secret'
        )
      end
    end
  end
end
