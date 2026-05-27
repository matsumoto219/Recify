require 'rails_helper'

RSpec.describe 'filter_parameter_logging' do
  let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  it 'filters passkey registration credential payloads' do
    params = {
      credential: {
        id: 'credential-id',
        rawId: 'raw-id',
        response: {
          attestationObject: 'attestation-object',
          clientDataJSON: 'client-data-json'
        }
      },
      label: 'MacBook Touch ID'
    }

    filtered = filter.filter(params)

    aggregate_failures do
      expect(filtered[:credential]).to eq('[FILTERED]')
      expect(filtered[:label]).to eq('MacBook Touch ID')
    end
  end

  it 'filters WebAuthn material keys when they appear outside the credential wrapper' do
    params = {
      rawId: 'raw-id',
      raw_id: 'raw-id',
      attestationObject: 'attestation-object',
      attestation_object: 'attestation-object',
      clientDataJSON: 'client-data-json',
      client_data_json: 'client-data-json',
      authenticatorData: 'authenticator-data',
      authenticator_data: 'authenticator-data',
      publicKey: 'public-key',
      public_key: 'public-key',
      credential_id: 'credential-id',
      challenge: 'challenge',
      signature: 'signature',
      userHandle: 'user-handle',
      user_handle: 'user-handle',
      id: 'ordinary-id'
    }

    filtered = filter.filter(params)

    aggregate_failures do
      expect(filtered.except(:id).values).to all(eq('[FILTERED]'))
      expect(filtered[:id]).to eq('ordinary-id')
    end
  end

  it 'filters TOTP and recovery code material recursively without filtering ordinary ids' do
    params = {
      id: 'ordinary-id',
      totp: '123456',
      otp_attempt: '123456',
      totp_code: '123456',
      totp_secret: 'totp-secret',
      encrypted_totp_secret: 'encrypted-secret',
      recovery_code: 'recovery-secret',
      recovery_codes: [ 'recovery-secret-1', 'recovery-secret-2' ],
      backup_code: 'backup-secret',
      backup_codes: [ 'backup-secret' ],
      provisioning_uri: 'otpauth://totp/Recify',
      otpauth: 'otpauth://totp/Recify',
      two_factor: { enabled: true, totp_secret: 'nested-totp-secret' },
      second_factor: { recovery_code: 'nested-recovery-secret' },
      one_time_password: '654321',
      safe_count: 2
    }

    filtered = filter.filter(params)

    aggregate_failures do
      expect(filtered.except(:id, :safe_count).values).to all(eq('[FILTERED]'))
      expect(filtered[:id]).to eq('ordinary-id')
      expect(filtered[:safe_count]).to eq(2)
    end
  end
end
