require 'rails_helper'

RSpec.describe RecoveryCode, type: :model do
  describe 'associations' do
    it 'userに属する' do
      recovery_code = create(:recovery_code)

      expect(recovery_code.user).to be_present
    end
  end

  describe 'validations' do
    it 'code_digestを必須にする' do
      recovery_code = build(:recovery_code, code_digest: nil)

      expect(recovery_code).not_to be_valid
      expect(recovery_code.errors[:code_digest]).to be_present
    end

    it 'code_digestの重複を不正にする' do
      digest = TwoFactor.recovery_code_digest('duplicate-code')
      create(:recovery_code, code_digest: digest)
      recovery_code = build(:recovery_code, code_digest: digest)

      expect(recovery_code).not_to be_valid
      expect(recovery_code.errors[:code_digest]).to be_present
    end
  end

  describe '#used?' do
    it 'used_atがある場合trueを返す' do
      expect(build(:recovery_code, used_at: Time.current)).to be_used
    end

    it 'used_atがない場合falseを返す' do
      expect(build(:recovery_code, used_at: nil)).not_to be_used
    end
  end

  describe 'indexes' do
    it 'code_digestにunique indexを持つ' do
      index = ActiveRecord::Base.connection.indexes(:recovery_codes).find do |candidate|
        candidate.columns == [ 'code_digest' ]
      end

      expect(index).to be_present
      expect(index.unique).to be(true)
    end
  end
end
