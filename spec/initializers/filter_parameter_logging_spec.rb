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
      code: '123456',
      authentication_code: 'authentication-secret',
      verification_code: 'verification-secret',
      auth_code: 'auth-secret',
      totp: '123456',
      otp_attempt: '123456',
      otp_code: '123456',
      totp_code: '123456',
      two_factor_code: '123456',
      totp_secret: 'totp-secret',
      encrypted_totp_secret: 'encrypted-secret',
      recovery_code: 'recovery-secret',
      recovery_codes: [ 'recovery-secret-1', 'recovery-secret-2' ],
      recovery_codes_count: 2,
      backup_code: 'backup-secret',
      backup_codes: [ 'backup-secret' ],
      backup_codes_count: 1,
      provisioning_uri: 'otpauth://totp/Recify',
      otpauth: 'otpauth://totp/Recify',
      two_factor: { enabled: true, totp_secret: 'nested-totp-secret' },
      second_factor: { recovery_code: 'nested-recovery-secret' },
      one_time_password: '654321',
      error_code: 'validation_failed',
      postal_code: '100-0001',
      quantity_unit_code: 'each',
      safe_count: 2
    }

    filtered = filter.filter(params)
    payload = filtered.to_json

    aggregate_failures do
      expect(payload).not_to include(
        'authentication-secret',
        'verification-secret',
        'auth-secret'
      )
      expect(filtered.except(:id, :safe_count, :recovery_codes_count, :backup_codes_count, :error_code, :postal_code, :quantity_unit_code).values).to all(eq('[FILTERED]'))
      expect(filtered[:id]).to eq('ordinary-id')
      expect(filtered[:code]).to eq('[FILTERED]')
      expect(filtered[:authentication_code]).to eq('[FILTERED]')
      expect(filtered[:verification_code]).to eq('[FILTERED]')
      expect(filtered[:auth_code]).to eq('[FILTERED]')
      expect(filtered[:error_code]).to eq('validation_failed')
      expect(filtered[:postal_code]).to eq('100-0001')
      expect(filtered[:quantity_unit_code]).to eq('each')
      expect(filtered[:safe_count]).to eq(2)
      expect(filtered[:recovery_codes_count]).to eq(2)
      expect(filtered[:backup_codes_count]).to eq(1)
    end
  end

  it 'filters digest and session identifiers recursively' do
    params = {
      code_digest: 'code-digest',
      session_uid: 'raw-session-uid',
      session_uid_digest: 'session-digest',
      nested: {
        codeDigest: 'camel-code-digest',
        sessionUid: 'camel-session-uid',
        sessionUidDigest: 'camel-session-digest'
      },
      array: [
        {
          code_digest: 'array-code-digest',
          session_uid_digest: 'array-session-digest'
        }
      ]
    }

    filtered = filter.filter(params)

    aggregate_failures do
      expect(filtered[:code_digest]).to eq('[FILTERED]')
      expect(filtered[:session_uid]).to eq('[FILTERED]')
      expect(filtered[:session_uid_digest]).to eq('[FILTERED]')
      expect(filtered[:nested][:codeDigest]).to eq('[FILTERED]')
      expect(filtered[:nested][:sessionUid]).to eq('[FILTERED]')
      expect(filtered[:nested][:sessionUidDigest]).to eq('[FILTERED]')
      expect(filtered[:array].first[:code_digest]).to eq('[FILTERED]')
      expect(filtered[:array].first[:session_uid_digest]).to eq('[FILTERED]')
    end
  end

  it 'filters provider, authorization, and Active Storage identifiers recursively' do
    params = {
      authorization: 'Bearer raw-token',
      endpoint: 'https://internal-provider.example.test',
      azure_ocr_api_key: 'azure-secret',
      openai_api_key: 'openai-secret',
      signed_id: 'signed-storage-id',
      blob_key: 'active-storage-key',
      storage_key: 'storage-key',
      checksum: 'storage-checksum',
      content_md5: 'storage-md5',
      nested: {
        signedId: 'nested-signed-id',
        blobKey: 'nested-blob-key',
        storageKey: 'nested-storage-key',
        checksum: 'nested-checksum'
      },
      safe_label: 'receipt image'
    }

    filtered = filter.filter(params)

    aggregate_failures do
      expect(filtered[:authorization]).to eq('[FILTERED]')
      expect(filtered[:endpoint]).to eq('[FILTERED]')
      expect(filtered[:azure_ocr_api_key]).to eq('[FILTERED]')
      expect(filtered[:openai_api_key]).to eq('[FILTERED]')
      expect(filtered[:signed_id]).to eq('[FILTERED]')
      expect(filtered[:blob_key]).to eq('[FILTERED]')
      expect(filtered[:storage_key]).to eq('[FILTERED]')
      expect(filtered[:checksum]).to eq('[FILTERED]')
      expect(filtered[:content_md5]).to eq('[FILTERED]')
      expect(filtered[:nested].values).to all(eq('[FILTERED]'))
      expect(filtered[:safe_label]).to eq('receipt image')
    end
  end

  it 'filters authentication and recovery token query parameters' do
    query = Rack::Utils.parse_nested_query(
      [
        'confirmation_token=raw-confirmation-token',
        'reset_password_token=raw-reset-token',
        'unlock_token=raw-unlock-token',
        'invitation_token=raw-invitation-token',
        'token=raw-generic-token',
        'authentication_code=raw-authentication-code',
        'verification_code=raw-verification-code',
        'q=receipt'
      ].join('&')
    )

    filtered = filter.filter(query)
    payload = filtered.to_json

    aggregate_failures do
      expect(payload).not_to include(
        'raw-confirmation-token',
        'raw-reset-token',
        'raw-unlock-token',
        'raw-invitation-token',
        'raw-generic-token',
        'raw-authentication-code',
        'raw-verification-code'
      )
      expect(filtered.fetch('confirmation_token')).to eq('[FILTERED]')
      expect(filtered.fetch('reset_password_token')).to eq('[FILTERED]')
      expect(filtered.fetch('unlock_token')).to eq('[FILTERED]')
      expect(filtered.fetch('invitation_token')).to eq('[FILTERED]')
      expect(filtered.fetch('token')).to eq('[FILTERED]')
      expect(filtered.fetch('authentication_code')).to eq('[FILTERED]')
      expect(filtered.fetch('verification_code')).to eq('[FILTERED]')
      expect(filtered.fetch('q')).to eq('receipt')
    end
  end

  it 'filters bot challenge response parameters' do
    params = {
      "cf-turnstile-response" => "raw-turnstile-response",
      "cf_turnstile_response" => "raw-underscore-turnstile-response",
      "g-recaptcha-response" => "raw-recaptcha-response",
      safe_field: "signup"
    }

    filtered = filter.filter(params)
    payload = filtered.to_json

    aggregate_failures do
      expect(payload).not_to include(
        "raw-turnstile-response",
        "raw-underscore-turnstile-response",
        "raw-recaptcha-response"
      )
      expect(filtered.fetch("cf-turnstile-response")).to eq("[FILTERED]")
      expect(filtered.fetch("cf_turnstile_response")).to eq("[FILTERED]")
      expect(filtered.fetch("g-recaptcha-response")).to eq("[FILTERED]")
      expect(filtered.fetch(:safe_field)).to eq("signup")
    end
  end
end
