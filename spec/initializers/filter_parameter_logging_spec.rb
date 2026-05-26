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
end
