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
end
