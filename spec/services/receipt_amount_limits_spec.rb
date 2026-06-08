require 'rails_helper'

RSpec.describe ReceiptAmountLimits do
  describe '.limit_for' do
    it 'default上限を返す' do
      aggregate_failures do
        expect(described_class.receipt_total_amount_max).to eq(999_999_999)
        expect(described_class.receipt_item_price_max).to eq(999_999_999)
        expect(described_class.receipt_item_line_total_max).to eq(999_999_999)
        expect(described_class.receipt_tax_amount_max).to eq(999_999_999)
        expect(described_class.receipt_adjustment_amount_max).to eq(999_999_999)
        expect(described_class.receipt_payment_amount_max).to eq(999_999_999)
      end
    end

    it 'SystemSettings値を返す' do
      create(:system_setting, key: 'limits.receipt_total_amount_max', value: SystemSettings.stored_value(2_000_000_000))
      create(:system_setting, key: 'limits.receipt_item_line_total_max', value: SystemSettings.stored_value(1_500_000_000))
      create(:system_setting, key: 'limits.receipt_item_price_max', value: SystemSettings.stored_value(1_200_000_000))

      aggregate_failures do
        expect(described_class.receipt_total_amount_max).to eq(2_000_000_000)
        expect(described_class.receipt_item_line_total_max).to eq(1_500_000_000)
        expect(described_class.receipt_item_price_max).to eq(1_200_000_000)
      end
    end

    it '取得に失敗した場合は既存defaultへfallbackする' do
      allow(SystemSettings).to receive(:limit_for).and_raise(SystemSettings::ValidationError, 'invalid')

      expect(described_class.receipt_payment_amount_max).to eq(999_999_999)
    end
  end
end
