require 'rails_helper'

RSpec.describe ReceiptAdjustmentOwnershipPolicy do
  describe '.bag_fee_owned_text?' do
    it '明示的な袋代表現だけをfee-ownedとして扱う' do
      aggregate_failures do
        expect(described_class.bag_fee_owned_text?('レジ袋代', profile: ReceiptAnalysisProfiles.default)).to be(true)
        expect(described_class.bag_fee_owned_text?('袋代 ¥10', profile: ReceiptAnalysisProfiles.default)).to be(true)
        expect(described_class.bag_fee_owned_text?('レジ袋中1枚', profile: ReceiptAnalysisProfiles.default)).to be(false)
      end
    end
  end
end
