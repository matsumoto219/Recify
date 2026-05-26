require 'rails_helper'
require 'webauthn/fake_client'

RSpec.describe Passkeys do
  let(:origin) { 'http://localhost:3000' }
  let(:rp_id) { 'localhost' }
  let(:client) { WebAuthn::FakeClient.new(origin) }

  describe '.registration_options' do
    it '親入口からregistration optionsを生成し、user handleを保存する' do
      user = create(:user, webauthn_id: nil)

      options = described_class.registration_options(user: user)

      aggregate_failures do
        expect(options.challenge).to be_present
        expect(options.rp.id).to eq(rp_id)
        expect(options.rp.name).to eq('Recify')
        expect(user.reload.webauthn_id).to be_present
        expect(options.user.id).to eq(user.webauthn_id)
      end
    end
  end

  describe '.verify_registration' do
    it 'registration responseを検証してpasskeyを保存する' do
      user = create(:user)
      options = described_class.registration_options(user: user)
      credential = client.create(
        challenge: options.challenge,
        rp_id: rp_id,
        user_verified: true,
        backup_eligibility: true,
        backup_state: true
      )

      passkey = described_class.verify_registration(
        user: user,
        credential: credential,
        challenge: options.challenge,
        label: 'MacBook Touch ID'
      )

      aggregate_failures do
        expect(passkey).to be_persisted
        expect(passkey.user).to eq(user)
        expect(passkey.credential_id).to be_present
        expect(passkey.public_key).to be_present
        expect(passkey.sign_count).to eq(0)
        expect(passkey.label).to eq('MacBook Touch ID')
        expect(passkey.transports).to eq([ 'internal' ])
        expect(passkey.backup_eligible).to be(true)
        expect(passkey.backed_up).to be(true)
      end
    end

    it 'duplicate credentialを拒否する' do
      user = create(:user)
      options = described_class.registration_options(user: user)
      credential = client.create(challenge: options.challenge, rp_id: rp_id, user_verified: true)
      credential_id = WebAuthn::Credential.from_create(credential).id
      create(:passkey, credential_id: credential_id)

      expect {
        described_class.verify_registration(user: user, credential: credential, challenge: options.challenge)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe '.authentication_options' do
    it '登録済みpasskeyをallow listに含める' do
      user = create(:user)
      passkey = create(:passkey, user: user)

      options = described_class.authentication_options(user: user)

      expect(options.allow_credentials.first[:id]).to eq(passkey.credential_id)
    end
  end

  describe '.verify_authentication' do
    it 'authentication responseを検証してsign_countとlast_used_atを更新する' do
      user = create(:user)
      passkey = create_passkey_with_fake_client(user)
      options = described_class.authentication_options(user: user)
      credential = client.get(
        challenge: options.challenge,
        rp_id: rp_id,
        user_verified: true,
        allow_credentials: [ passkey.credential_id ]
      )

      result = described_class.verify_authentication(
        credential: credential,
        challenge: options.challenge
      )

      aggregate_failures do
        expect(result.user).to eq(user)
        expect(result.passkey).to eq(passkey)
        expect(passkey.reload.sign_count).to be > 0
        expect(passkey.last_used_at).to be_present
      end
    end

    it '指定userとcredentialの所有者が違う場合は拒否する' do
      passkey = create_passkey_with_fake_client(create(:user))
      other_user = create(:user)
      options = WebAuthn::Credential.options_for_get(
        allow: [ passkey.credential_id ],
        user_verification: 'required'
      )
      credential = client.get(
        challenge: options.challenge,
        rp_id: rp_id,
        user_verified: true,
        allow_credentials: [ passkey.credential_id ]
      )

      expect {
        described_class.verify_authentication(
          credential: credential,
          challenge: options.challenge,
          user: other_user
        )
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe '.reauthentication_options and .verify_reauthentication' do
    it '同じcredentialで再認証ceremonyを成立させる' do
      user = create(:user)
      passkey = create_passkey_with_fake_client(user)
      options = described_class.reauthentication_options(user: user)
      credential = client.get(
        challenge: options.challenge,
        rp_id: rp_id,
        user_verified: true,
        allow_credentials: [ passkey.credential_id ]
      )

      result = described_class.verify_reauthentication(
        user: user,
        credential: credential,
        challenge: options.challenge
      )

      expect(result.user).to eq(user)
      expect(passkey.reload.last_used_at).to be_present
    end
  end

  def create_passkey_with_fake_client(user)
    options = described_class.registration_options(user: user)
    credential = client.create(challenge: options.challenge, rp_id: rp_id, user_verified: true)

    described_class.verify_registration(user: user, credential: credential, challenge: options.challenge)
  end
end
