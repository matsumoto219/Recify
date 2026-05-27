require 'rails_helper'

RSpec.describe TotpCredential, type: :model do
  describe 'associations' do
    it 'userに属する' do
      credential = create(:totp_credential)

      expect(credential.user).to be_present
    end
  end

  describe 'validations' do
    it 'totp_secretを必須にする' do
      credential = build(:totp_credential, totp_secret: nil)

      expect(credential).not_to be_valid
      expect(credential.errors[:totp_secret]).to be_present
    end

    it 'userごとに1件だけ許可する' do
      user = create(:user)
      create(:totp_credential, user: user)
      credential = build(:totp_credential, user: user)

      expect(credential).not_to be_valid
      expect(credential.errors[:user_id]).to be_present
    end
  end

  describe '#confirmed?' do
    it 'confirmed_atがある場合trueを返す' do
      expect(build(:totp_credential, confirmed_at: Time.current)).to be_confirmed
    end

    it 'confirmed_atがない場合falseを返す' do
      expect(build(:totp_credential, confirmed_at: nil)).not_to be_confirmed
    end
  end

  describe 'encryption' do
    it 'totp_secretを暗号化して保存する' do
      secret = ROTP::Base32.random
      credential = create(:totp_credential, totp_secret: secret)
      raw_value = ActiveRecord::Base.connection.select_value(
        "SELECT totp_secret FROM totp_credentials WHERE id = #{credential.id}"
      )

      aggregate_failures do
        expect(credential.reload.totp_secret).to eq(secret)
        expect(raw_value).not_to eq(secret)
        expect(raw_value).not_to include(secret)
      end
    end
  end

  describe 'indexes' do
    it 'user_idにunique indexを持つ' do
      index = ActiveRecord::Base.connection.indexes(:totp_credentials).find do |candidate|
        candidate.columns == [ 'user_id' ] && candidate.unique
      end

      expect(index).to be_present
    end
  end
end
