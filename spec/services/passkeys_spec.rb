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
        expect(options.as_json.dig(:authenticatorSelection, :userVerification)).to eq('required')
        expect(options.as_json.dig(:authenticatorSelection, :residentKey)).to eq('required')
        expect(options.as_json.dig(:authenticatorSelection, :requireResidentKey)).to be(true)
      end
    end
  end

  describe '.registration_limit' do
    it 'passkey登録上限を返す' do
      expect(described_class.registration_limit).to eq(Passkey::MAX_PER_USER)
    end
  end

  describe '.count_for' do
    it 'userの登録済みpasskey数を返す' do
      user = create(:user)
      create_list(:passkey, 3, user: user)

      expect(described_class.count_for(user)).to eq(3)
    end

    it 'userがnilの場合は0を返す' do
      expect(described_class.count_for(nil)).to eq(0)
    end
  end

  describe '.remaining_slots_for' do
    it '残り登録可能数を返す' do
      user = create(:user)
      create_list(:passkey, 4, user: user)

      expect(described_class.remaining_slots_for(user)).to eq(Passkey::MAX_PER_USER - 4)
    end

    it '上限到達時は0を返す' do
      user = create(:user)
      create_list(:passkey, Passkey::MAX_PER_USER, user: user)

      expect(described_class.remaining_slots_for(user)).to eq(0)
    end

    it 'guest userは安全側に倒して0を返す' do
      guest = User.guest!

      expect(described_class.remaining_slots_for(guest)).to eq(0)
    end
  end

  describe '.registration_limit_reached?' do
    it '登録数が上限未満ならfalseを返す' do
      user = create(:user)
      create_list(:passkey, Passkey::MAX_PER_USER - 1, user: user)

      expect(described_class.registration_limit_reached?(user)).to be(false)
    end

    it '登録数が上限に達している場合はtrueを返す' do
      user = create(:user)
      create_list(:passkey, Passkey::MAX_PER_USER, user: user)

      expect(described_class.registration_limit_reached?(user)).to be(true)
    end

    it 'nil userは安全側に倒してtrueを返す' do
      expect(described_class.registration_limit_reached?(nil)).to be(true)
    end

    it 'guest userは安全側に倒してtrueを返す' do
      guest = User.guest!

      expect(described_class.registration_limit_reached?(guest)).to be(true)
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

  describe '.discoverable_authentication_options' do
    it 'discoverable credential login用にallow credentialsなしでoptionsを生成する' do
      options = described_class.discoverable_authentication_options

      aggregate_failures do
        expect(options.challenge).to be_present
        expect(options.rp_id).to eq(rp_id)
        expect(options.user_verification).to eq('required')
        expect(options.allow_credentials).to eq([])
        expect(options.as_json.fetch(:allowCredentials)).to eq([])
      end
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

  describe '.verify_discoverable_authentication' do
    it 'discoverable authentication responseを検証してuserを返し、sign_countとlast_used_atを更新する' do
      user = create(:user)
      passkey = create_passkey_with_fake_client(user)
      options = described_class.discoverable_authentication_options
      credential = client.get(
        challenge: options.challenge,
        rp_id: rp_id,
        user_verified: true,
        user_handle: raw_user_handle_for(user)
      )

      result = described_class.verify_discoverable_authentication(
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

    it 'user_handleがcredential所有者と一致しない場合は拒否する' do
      passkey = create_passkey_with_fake_client(create(:user))
      other_user = create(:user)
      options = described_class.discoverable_authentication_options
      credential = client.get(
        challenge: options.challenge,
        rp_id: rp_id,
        user_verified: true,
        user_handle: raw_user_handle_for(other_user)
      )

      expect {
        described_class.verify_discoverable_authentication(
          credential: credential,
          challenge: options.challenge
        )
      }.to raise_error(Passkeys::AuthenticationError)

      expect(passkey.reload.last_used_at).to be_blank
    end

    it 'user_handleがない場合は拒否する' do
      passkey = create_passkey_with_fake_client(create(:user))
      options = described_class.discoverable_authentication_options
      credential = client.get(
        challenge: options.challenge,
        rp_id: rp_id,
        user_verified: true
      )

      expect {
        described_class.verify_discoverable_authentication(
          credential: credential,
          challenge: options.challenge
        )
      }.to raise_error(Passkeys::AuthenticationError)

      expect(passkey.reload.last_used_at).to be_blank
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

  describe '.step_up_options and .verify_step_up' do
    it 'user指定ありのpasskey step-up ceremonyを成立させる' do
      user = create(:user)
      passkey = create_passkey_with_fake_client(user)
      options = described_class.step_up_options(user: user)
      credential = client.get(
        challenge: options.challenge,
        rp_id: rp_id,
        user_verified: true,
        allow_credentials: [ passkey.credential_id ]
      )

      result = described_class.verify_step_up(
        user: user,
        credential: credential,
        challenge: options.challenge
      )

      aggregate_failures do
        expect(options.allow_credentials.first[:id]).to eq(passkey.credential_id)
        expect(options.user_verification).to eq('required')
        expect(result.user).to eq(user)
        expect(passkey.reload.last_used_at).to be_present
      end
    end
  end

  def create_passkey_with_fake_client(user)
    options = described_class.registration_options(user: user)
    credential = client.create(challenge: options.challenge, rp_id: rp_id, user_verified: true)

    described_class.verify_registration(user: user, credential: credential, challenge: options.challenge)
  end

  def raw_user_handle_for(user)
    WebAuthn.standard_encoder.decode(user.ensure_webauthn_id!)
  end
end
