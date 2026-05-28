require 'rails_helper'

RSpec.describe ReceiptsHelper, type: :helper do
  describe '#receipt_item_discount_label' do
    def discount_item(discount_amount:, original_line_total:, discount_rate: nil)
      instance_double(
        ReceiptItem,
        discount_amount: discount_amount,
        original_line_total: original_line_total,
        discount_rate: discount_rate
      )
    end

    it 'discount_rate が 0.5 の場合は50%表示にする' do
      item = discount_item(discount_amount: 245, original_line_total: 489, discount_rate: BigDecimal('0.5'))

      expect(helper.receipt_item_discount_label(item)).to eq('割引: -¥245（50%）')
    end

    it 'discount_rate が 0.501 の場合は50.1%表示にする' do
      item = discount_item(discount_amount: 245, original_line_total: 489, discount_rate: BigDecimal('0.501'))

      expect(helper.receipt_item_discount_label(item)).to eq('割引: -¥245（50.1%）')
    end

    it 'discount_rate がない場合はdiscount_amountとoriginal_line_totalから推定表示する' do
      item = discount_item(discount_amount: 245, original_line_total: 489)

      expect(helper.receipt_item_discount_label(item)).to eq('割引: -¥245（50.1%）')
    end

    it 'discount_amount がnilの場合は割引表示を出さない' do
      item = discount_item(discount_amount: nil, original_line_total: 489, discount_rate: BigDecimal('0.5'))

      expect(helper.receipt_item_discount_label(item)).to be_nil
    end

    it 'original_line_total がnilの場合は割引率を出さない' do
      item = discount_item(discount_amount: 245, original_line_total: nil, discount_rate: BigDecimal('0.5'))

      expect(helper.receipt_item_discount_label(item)).to eq('割引: -¥245')
    end

    it 'original_line_total が0の場合は割引率を出さない' do
      item = discount_item(discount_amount: 245, original_line_total: 0, discount_rate: BigDecimal('0.5'))

      expect(helper.receipt_item_discount_label(item)).to eq('割引: -¥245')
    end
  end
end
