require 'rails_helper'

RSpec.describe ReceiptItem, type: :model do
  describe 'quantity validation' do
    def build_item(quantity:, quantity_unit:)
      build(:receipt).receipt_items.build(
        confirmed_name: '数量確認商品',
        price: 100,
        quantity: quantity,
        quantity_unit: quantity_unit,
        line_total: 100,
        needs_review: false
      )
    end

    it 'integer-only unitでは小数quantityを許可しない' do
      item = build_item(quantity: BigDecimal('1.1'), quantity_unit: '個')

      aggregate_failures do
        expect(item).not_to be_valid
        expect(item.errors[:quantity]).to include(I18n.t('activerecord.errors.models.receipt_item.attributes.quantity.must_be_integer_for_unit'))
      end
    end

    it 'integer-only unitでは整数quantityを許可する' do
      item = build_item(quantity: BigDecimal('1'), quantity_unit: '個')

      expect(item).to be_valid
    end

    it 'その他では小数quantityを許可しない' do
      item = build_item(quantity: BigDecimal('1.1'), quantity_unit: 'その他')

      expect(item).not_to be_valid
    end

    it '未知単位では小数quantityを許可しない' do
      item = build_item(quantity: BigDecimal('1.1'), quantity_unit: '束')

      expect(item).not_to be_valid
    end

    it 'measurement unitでは小数quantityを許可する' do
      aggregate_failures do
        expect(build_item(quantity: BigDecimal('0.3'), quantity_unit: 'kg')).to be_valid
        expect(build_item(quantity: BigDecimal('1.25'), quantity_unit: 'ml')).to be_valid
      end
    end

    it '負数quantityは引き続き許可しない' do
      item = build_item(quantity: BigDecimal('-1'), quantity_unit: 'kg')

      expect(item).not_to be_valid
    end
  end

  describe 'amount limit validation' do
    it 'SystemSettingsの明細単価/合計上限を参照する' do
      create(:system_setting, key: 'limits.receipt_item_price_max', value: SystemSettings.stored_value(500))
      create(:system_setting, key: 'limits.receipt_item_line_total_max', value: SystemSettings.stored_value(800))

      item = build(
        :receipt
      ).receipt_items.build(
        confirmed_name: '高額商品',
        price: 501,
        line_total: 801,
        original_line_total: 801,
        discount_amount: 801,
        quantity: 1,
        needs_review: false
      )

      aggregate_failures do
        expect(item).not_to be_valid
        expect(item.errors[:price]).to be_present
        expect(item.errors[:line_total]).to be_present
        expect(item.errors[:original_line_total]).to be_present
        expect(item.errors[:discount_amount]).to be_present
      end
    end
  end

  describe 'per receipt limit' do
    it 'direct createでもuser limitを超える明細を拒否する' do
      user = create(:user)
      create(:user_limit_override, user: user, key: 'receipt_items_per_receipt', value: { 'value' => 1 })
      receipt = create(:receipt, user: user)
      receipt.receipt_items.create!(confirmed_name: '既存', price: 100, quantity: 1, line_total: 100)

      item = receipt.receipt_items.build(confirmed_name: '追加', price: 100, quantity: 1, line_total: 100)

      aggregate_failures do
        expect(item).not_to be_valid
        expect(item.errors.of_kind?(:receipt, :receipt_items_limit_exceeded)).to be(true)
      end
    end
  end
end
