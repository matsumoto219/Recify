require 'rails_helper'

RSpec.describe ReceiptFormPresenter do
  describe '#error_flags' do
    it 'maps receipt review reasons to field flags' do
      receipt = build(
        :receipt,
        review_reasons: %w[store_name_missing payment_method_uncertain purchased_at_conflicted]
      )

      flags = described_class.new(receipt: receipt).error_flags

      aggregate_failures do
        expect(flags[:store_name]).to be(true)
        expect(flags[:payment_method]).to be(true)
        expect(flags[:purchased_at]).to be(true)
        expect(flags[:store_address]).to be(false)
      end
    end
  end

  describe '#item_row' do
    it 'builds item row state from review reasons and quantity unit' do
      receipt = build(:receipt)
      item = ReceiptItem.new(
        receipt: receipt,
        quantity_unit_code: 'kilogram',
        tax_rate: BigDecimal('0.08'),
        needs_review: true,
        review_reasons: %w[item_name_uncertain item_tax_rate_uncertain price_tax_inclusion_uncertain]
      )

      row = described_class.new(receipt: receipt).item_row(item, new_record: false)

      aggregate_failures do
        expect(row.selected_unit).to eq('kilogram')
        expect(row.quantity_step).to eq('0.001')
        expect(row.quantity_inputmode).to eq('decimal')
        expect(row.name_highlight_variant).to eq(:error)
        expect(row.tax_rate_highlight_variant).to eq(:error)
        expect(row.tax_rate_percentage_value).to eq(8)
        expect(row.warning_reason_labels).to be_present
      end
    end
  end

  describe '#adjustment_row' do
    it 'builds adjustment row state from kind and tax rate' do
      receipt = build(:receipt)
      adjustment = build(:receipt_adjustment, receipt: receipt, kind: 'other', sign: nil, tax_rate: BigDecimal('0.1'))

      row = described_class.new(receipt: receipt).adjustment_row(adjustment, new_record: false)

      aggregate_failures do
        expect(row.selected_kind).to eq('other')
        expect(row.selected_sign).to eq('discount')
        expect(row.other_kind?).to be(true)
        expect(row.sign_select_disabled?).to be(false)
        expect(row.tax_rate_value).to eq(10)
      end
    end
  end
end
