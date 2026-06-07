require 'rails_helper'

RSpec.describe Amounts::TaxRateGroup do
  describe '.from_gross' do
    it '任意税率の税込対象額から税抜・税額を逆算する' do
      # 検算: 1,075 * 7.5 / 107.5 = 75, 税抜は 1,075 - 75 = 1,000
      group = described_class.from_gross(
        rate: BigDecimal('0.075'),
        gross: 1_075,
        rounding_mode: :floor,
        rounding_scope: :per_tax_rate_group
      )

      expect(group.to_h).to include(
        rate: BigDecimal('0.075'),
        gross: 1_075,
        net: 1_000,
        tax: 75,
        rounding_mode: :floor,
        rounding_scope: :per_tax_rate_group
      )
    end
  end

  describe '.from_net' do
    it '任意税率の税抜対象額から税込・税額を計算する' do
      # 検算: 1,000 * 5% = 50, 税込は 1,050
      group = described_class.from_net(
        rate: BigDecimal('0.05'),
        net: 1_000,
        rounding_mode: :ceil,
        rounding_scope: :per_receipt
      )

      expect(group.to_h).to include(
        rate: BigDecimal('0.05'),
        gross: 1_050,
        net: 1_000,
        tax: 50,
        rounding_mode: :ceil,
        rounding_scope: :per_receipt
      )
    end
  end
end
