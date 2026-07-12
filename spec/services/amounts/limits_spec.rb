require 'rails_helper'

RSpec.describe Amounts::Limits do
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

  describe '.violations_for' do
    it '金額上限超過をresource/field/limit/actual_value付きで返す' do
      create(:system_setting, key: 'limits.receipt_item_price_max', value: SystemSettings.stored_value(400))
      create(:system_setting, key: 'limits.receipt_item_line_total_max', value: SystemSettings.stored_value(500))
      create(:system_setting, key: 'limits.receipt_tax_amount_max', value: SystemSettings.stored_value(300))
      create(:system_setting, key: 'limits.receipt_adjustment_amount_max', value: SystemSettings.stored_value(200))
      create(:system_setting, key: 'limits.receipt_payment_amount_max', value: SystemSettings.stored_value(500))
      create(:system_setting, key: 'limits.receipt_total_amount_max', value: SystemSettings.stored_value(500))

      violations = described_class.violations_for(
        receipt: { total_amount: 501, tax_amount: 301 },
        receipt_items: [
          { price: 401, line_total: 501 }
        ],
        receipt_adjustments: [
          { amount: 201 }
        ],
        receipt_payments: [
          { amount: 501 }
        ],
        receipt_tax_details: [
          { amount: 301, net_amount: 301 }
        ]
      )

      aggregate_failures do
        expect(violations).to include(
          hash_including(resource: 'receipt', field: 'total_amount', limit: 500, actual_value: 501),
          hash_including(resource: 'receipt', field: 'tax_amount', limit: 300, actual_value: 301),
          hash_including(resource: 'receipt_items', field: 'price', limit: 400, actual_value: 401, index: 0),
          hash_including(resource: 'receipt_items', field: 'line_total', limit: 500, actual_value: 501, index: 0),
          hash_including(resource: 'receipt_adjustments', field: 'amount', limit: 200, actual_value: 201, index: 0),
          hash_including(resource: 'receipt_payments', field: 'amount', limit: 500, actual_value: 501, index: 0),
          hash_including(resource: 'receipt_tax_details', field: 'amount', limit: 300, actual_value: 301, index: 0),
          hash_including(resource: 'receipt_tax_details', field: 'net_amount', limit: 300, actual_value: 301, index: 0)
        )
      end
    end
  end

  describe '金額上限設定の連動' do
    it '設定値を大きくした場合もモデル検証とAI schemaが同じ上限を参照する' do
      configured_limit = 1_500_000_000
      create(:system_setting, key: 'limits.receipt_total_amount_max', value: SystemSettings.stored_value(configured_limit))
      create(:system_setting, key: 'limits.receipt_item_line_total_max', value: SystemSettings.stored_value(configured_limit))
      create(:system_setting, key: 'limits.receipt_item_price_max', value: SystemSettings.stored_value(configured_limit))
      create(:system_setting, key: 'limits.receipt_tax_amount_max', value: SystemSettings.stored_value(configured_limit))
      create(:system_setting, key: 'limits.receipt_adjustment_amount_max', value: SystemSettings.stored_value(configured_limit))
      create(:system_setting, key: 'limits.receipt_payment_amount_max', value: SystemSettings.stored_value(configured_limit))

      receipt = build(
        :receipt,
        total_amount: 1_200_000_000,
        subtotal_amount: 1_200_000_000,
        tax_amount: 1_200_000_000,
        tip_amount: 1_200_000_000
      )
      item = ReceiptItem.new(
        receipt: receipt,
        confirmed_name: '高額商品',
        price: 1_200_000_000,
        original_line_total: 1_200_000_000,
        line_total: 1_200_000_000,
        discount_amount: 0
      )
      adjustment = build(:receipt_adjustment, receipt: receipt, amount: 1_200_000_000)
      payment = ReceiptPayment.new(receipt: receipt, amount: 1_200_000_000)
      tax_detail = ReceiptTaxDetail.new(receipt: receipt, amount: 1_200_000_000, net_amount: 1_200_000_000)

      aggregate_failures do
        expect(described_class.receipt_total_amount_max).to eq(configured_limit)
        expect(receipt).to be_valid
        expect(item).to be_valid
        expect(adjustment).to be_valid
        expect(payment).to be_valid
        expect(tax_detail).to be_valid
        expect(
          Ai::ReceiptAnalysisSchema.to_json_schema.dig(
            'properties',
            'receipt_adjustments',
            'items',
            'properties',
            'amount',
            'maximum'
          )
        ).to eq(configured_limit)
      end
    end
  end
end
