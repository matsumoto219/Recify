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
          nested: {
            messages: [ { role: 'user', content: 'secret prompt' } ],
            result: 'ok',
            api_key: 'sk-test'
          },
          array: [
            { token: 'hidden', value: 'kept' },
            { authorization_header: 'Bearer secret', value: 'also kept' }
          ]
        },
        before_state: { password: 'hidden', status: 'failed' },
        after_state: { session: 'hidden', status: 'processing' }
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
      expect(log.metadata.to_json).not_to include('ocr raw', 'full prompt', 'sk-test', 'Bearer secret')
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
  end
end
