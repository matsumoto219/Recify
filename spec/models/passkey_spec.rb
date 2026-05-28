require 'rails_helper'

RSpec.describe Passkey, type: :model do
  describe 'associations' do
    it 'userに属する' do
      passkey = create(:passkey)

      expect(passkey.user).to be_present
    end
  end

  describe 'defaults' do
    it 'uidを自動生成する' do
      passkey = create(:passkey)

      aggregate_failures do
        expect(passkey.uid).to match(/\Apsk_[A-Za-z0-9]{16}\z/)
        expect(passkey.to_param).to eq(passkey.uid)
      end
    end

    it 'sign_countは0を初期値にする' do
      passkey = described_class.create!(user: create(:user), credential_id: 'credential-default-count', public_key: 'public-key')

      expect(passkey.sign_count).to eq(0)
    end

    it 'transportsは空配列を初期値にする' do
      passkey = described_class.create!(user: create(:user), credential_id: 'credential-default-transports', public_key: 'public-key')

      expect(passkey.transports).to eq([])
    end
  end

  describe 'validations' do
    it 'uidの重複を不正にする' do
      existing = create(:passkey)
      passkey = build(:passkey, uid: existing.uid)

      expect(passkey).not_to be_valid
      expect(passkey.errors[:uid]).to be_present
    end

    it 'credential_idの重複を不正にする' do
      create(:passkey, credential_id: 'duplicate-credential')
      passkey = build(:passkey, credential_id: 'duplicate-credential')

      expect(passkey).not_to be_valid
      expect(passkey.errors[:credential_id]).to be_present
    end

    it 'public_keyを必須にする' do
      passkey = build(:passkey, public_key: nil)

      expect(passkey).not_to be_valid
      expect(passkey.errors[:public_key]).to be_present
    end

    it 'sign_countは0以上の整数にする' do
      passkey = build(:passkey, sign_count: -1)

      expect(passkey).not_to be_valid
      expect(passkey.errors[:sign_count]).to be_present
    end

    it 'transportsを配列へ正規化する' do
      passkey = build(:passkey, transports: [ 'internal', :hybrid, nil, '', 'internal' ])

      passkey.valid?

      expect(passkey.transports).to eq([ 'internal', 'hybrid' ])
    end
  end

  describe 'indexes' do
    it 'uidにunique indexを持つ' do
      index = ActiveRecord::Base.connection.indexes(:passkeys).find do |candidate|
        candidate.name == 'index_passkeys_on_uid'
      end

      expect(index).to be_present
      expect(index.unique).to be(true)
    end

    it 'credential_idにunique indexを持つ' do
      index = ActiveRecord::Base.connection.indexes(:passkeys).find do |candidate|
        candidate.name == 'index_passkeys_on_credential_id'
      end

      expect(index).to be_present
      expect(index.unique).to be(true)
    end
  end
end
