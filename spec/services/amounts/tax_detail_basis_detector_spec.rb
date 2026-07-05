require 'rails_helper'

RSpec.describe Amounts::TaxDetailBasisDetector do
  it '2019年サンプルコンビニの税抜小計と最終税率対象額を区別する' do
    details = described_class.call([
      { rate: BigDecimal('0.08'), net_amount: 270, amount: 21, description: '8%対象' },
      { rate: BigDecimal('0.10'), net_amount: 300, amount: 30, description: '小計（税抜10%）' },
      { rate: BigDecimal('0.10'), net_amount: 820, amount: 74, description: '10%対象' }
    ])

    aggregate_failures do
      # 検算: 270 * 8% = 21.6 -> floor 21 なので net basis、税込対象は 270 + 21 = 291
      expect(details[0]).to include(
        basis: :net,
        printed_amount: 270,
        printed_amount_basis: :net_subtotal,
        target_net_amount: 270,
        target_tax_amount: 21,
        target_gross_amount: 291
      )
      # 検算: 同一10%の最終対象820があるため、300/30は小計として intermediate
      expect(details[1]).to include(
        basis: :intermediate,
        printed_amount: 300,
        printed_amount_basis: :intermediate,
        target_tax_amount: 30,
        intermediate: true
      )
      # 検算: 820 * 10 / 110 = 74.54 -> floor 74 なので gross basis、税抜対象は 820 - 74 = 746
      expect(details[2]).to include(
        basis: :gross,
        printed_amount: 820,
        printed_amount_basis: :gross_target,
        target_net_amount: 746,
        target_tax_amount: 74,
        target_gross_amount: 820
      )
    end
  end

  it 'descriptionがOCRで潰れても同一税率の中間税抜小計を区別する' do
    details = described_class.call([
      { rate: BigDecimal('0.08'), net_amount: 270, amount: 21, description: '消費税等' },
      { rate: BigDecimal('0.10'), net_amount: 300, amount: 30, description: '消費税等' },
      { rate: BigDecimal('0.10'), net_amount: 820, amount: 74, description: '内消費税等' }
    ])

    aggregate_failures do
      # 検算: 300 * 10% = 30 なので税抜小計。820 * 10 / 110 = 74.54 -> floor 74 の税込対象が後続するため中間行。
      expect(details[1]).to include(basis: :intermediate, intermediate: true)
      # 検算: 820は税込対象、税額74、税抜746として最終10%対象にする。
      expect(details[2]).to include(basis: :gross, target_net_amount: 746, target_gross_amount: 820)
    end
  end
end
