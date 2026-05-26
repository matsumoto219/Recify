require "rails_helper"
require "webauthn/fake_client"

RSpec.describe "WebAuthn isolated spike" do
  ORIGIN = "http://localhost:3000"
  RP_ID = "localhost"

  StoredCredential = Struct.new(
    :credential_id,
    :public_key,
    :sign_count,
    :transports,
    :backup_eligible,
    :backed_up,
    keyword_init: true
  )

  def registration_options(user_id: WebAuthn.generate_user_id)
    WebAuthn::Credential.options_for_create(
      user: {
        id: user_id,
        name: "passkey-user@example.test",
        display_name: "Passkey User"
      },
      exclude: [],
      authenticator_selection: { user_verification: "required" }
    )
  end

  def authentication_options(stored_credential)
    WebAuthn::Credential.options_for_get(
      allow: [ stored_credential.credential_id ],
      user_verification: "required"
    )
  end

  def register_credential(client:, options: registration_options)
    credential_payload = client.create(
      challenge: options.challenge,
      rp_id: RP_ID,
      user_verified: true,
      backup_eligibility: true,
      backup_state: true
    )
    credential = WebAuthn::Credential.from_create(credential_payload)

    credential.verify(options.challenge, user_verification: true)

    StoredCredential.new(
      credential_id: credential.id,
      public_key: credential.public_key,
      sign_count: credential.sign_count,
      transports: credential_payload.dig("response", "transports"),
      backup_eligible: credential.backup_eligible?,
      backed_up: credential.backed_up?
    )
  end

  def authenticate_credential(client:, stored_credential:, options: authentication_options(stored_credential))
    assertion_payload = client.get(
      challenge: options.challenge,
      rp_id: RP_ID,
      user_verified: true,
      allow_credentials: [ stored_credential.credential_id ]
    )
    assertion = WebAuthn::Credential.from_get(assertion_payload)

    assertion.verify(
      options.challenge,
      public_key: stored_credential.public_key,
      sign_count: stored_credential.sign_count,
      user_verification: true
    )

    [ assertion, assertion_payload ]
  end

  it "loads the Recify WebAuthn relying party configuration" do
    expect(WebAuthn.configuration.rp_name).to eq("Recify")
    expect(WebAuthn.configuration.rp_id).to eq(RP_ID)
    expect(WebAuthn.configuration.allowed_origins).to eq([ ORIGIN ])
    expect(WebAuthn.configuration.credential_options_timeout).to eq(120_000)
  end

  it "generates registration options with a challenge and relying party data" do
    options = registration_options

    expect(options.challenge).to be_present
    expect(options.rp.id).to eq(RP_ID)
    expect(options.rp.name).to eq("Recify")
    expect(options.user.id).to be_present
    expect(options.user.name).to eq("passkey-user@example.test")
  end

  it "registers a FakeClient credential and extracts future passkeys table values" do
    client = WebAuthn::FakeClient.new(ORIGIN)
    stored_credential = register_credential(client: client)

    expect(stored_credential.credential_id).to be_present
    expect(stored_credential.public_key).to be_present
    expect(stored_credential.sign_count).to eq(0)
    expect(stored_credential.transports).to include("internal")
    expect(stored_credential.backup_eligible).to be(true)
    expect(stored_credential.backed_up).to be(true)
  end

  it "authenticates a registered credential and updates the sign count" do
    client = WebAuthn::FakeClient.new(ORIGIN)
    stored_credential = register_credential(client: client)

    assertion, = authenticate_credential(client: client, stored_credential: stored_credential)

    expect(assertion.id).to eq(stored_credential.credential_id)
    expect(assertion.sign_count).to be > stored_credential.sign_count

    stored_credential.sign_count = assertion.sign_count
    next_assertion, = authenticate_credential(client: client, stored_credential: stored_credential)

    expect(next_assertion.sign_count).to be > assertion.sign_count
  end

  it "uses the same authentication ceremony shape for admin reauthentication" do
    client = WebAuthn::FakeClient.new(ORIGIN)
    stored_credential = register_credential(client: client)

    reauthentication_options = authentication_options(stored_credential)
    assertion, = authenticate_credential(
      client: client,
      stored_credential: stored_credential,
      options: reauthentication_options
    )

    reauthentication_session = {
      "reauthenticated" => true,
      "method" => "passkey",
      "reauthenticated_at" => Time.current.iso8601
    }

    expect(assertion.sign_count).to be > stored_credential.sign_count
    expect(reauthentication_session).not_to include(
      "challenge",
      "credential_id",
      "credential_response",
      "public_key"
    )
  end

  it "rejects a registration challenge mismatch" do
    client = WebAuthn::FakeClient.new(ORIGIN)
    options = registration_options
    credential_payload = client.create(challenge: options.challenge, rp_id: RP_ID, user_verified: true)
    credential = WebAuthn::Credential.from_create(credential_payload)

    expect {
      credential.verify(registration_options.challenge, user_verification: true)
    }.to raise_error(WebAuthn::ChallengeVerificationError)
  end

  it "rejects a replayed authentication assertion after sign_count is updated" do
    client = WebAuthn::FakeClient.new(ORIGIN)
    stored_credential = register_credential(client: client)
    options = authentication_options(stored_credential)

    assertion, assertion_payload = authenticate_credential(
      client: client,
      stored_credential: stored_credential,
      options: options
    )
    stored_credential.sign_count = assertion.sign_count
    replayed_assertion = WebAuthn::Credential.from_get(assertion_payload)

    expect {
      replayed_assertion.verify(
        authentication_options(stored_credential).challenge,
        public_key: stored_credential.public_key,
        sign_count: stored_credential.sign_count,
        user_verification: true
      )
    }.to raise_error(WebAuthn::ChallengeVerificationError)

    expect {
      replayed_assertion.verify(
        options.challenge,
        public_key: stored_credential.public_key,
        sign_count: stored_credential.sign_count,
        user_verification: true
      )
    }.to raise_error(WebAuthn::SignCountVerificationError)
  end

  it "rejects an origin mismatch" do
    client = WebAuthn::FakeClient.new("http://evil.example")
    options = registration_options
    credential_payload = client.create(challenge: options.challenge, rp_id: RP_ID, user_verified: true)
    credential = WebAuthn::Credential.from_create(credential_payload)

    expect {
      credential.verify(options.challenge, user_verification: true)
    }.to raise_error(WebAuthn::OriginVerificationError)
  end

  it "rejects an rp_id mismatch" do
    client = WebAuthn::FakeClient.new(ORIGIN)
    options = registration_options
    credential_payload = client.create(challenge: options.challenge, rp_id: "example.test", user_verified: true)
    credential = WebAuthn::Credential.from_create(credential_payload)

    expect {
      credential.verify(options.challenge, user_verification: true)
    }.to raise_error(WebAuthn::RpIdVerificationError)
  end
end
