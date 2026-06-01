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

  describe '#receipt_amount_summary_tax_detail_rows' do
    it 'builds display rows and tax included totals for tax details' do
      rows = helper.receipt_amount_summary_tax_detail_rows([
        { rate: BigDecimal('0.08'), net_amount: 1_000, amount: 80 },
        { 'rate' => BigDecimal('0.1'), 'net_amount' => 2_000, 'amount' => 200 }
      ])

      aggregate_failures do
        expect(rows.map(&:rate_label)).to eq(%w[8% 10%])
        expect(rows.map(&:amount_display)).to eq(%w[¥80 ¥200])
        expect(rows.map(&:net_amount_display)).to eq(%w[¥1,000 ¥2,000])
        expect(rows.map(&:total_display)).to eq(%w[¥1,080 ¥2,200])
      end
    end

    it 'keeps unavailable display when tax amount or net amount is missing' do
      row = helper.receipt_amount_summary_tax_detail_rows([{ rate: nil, net_amount: nil, amount: 80 }]).first

      aggregate_failures do
        expect(row.rate_label).to eq(I18n.t('receipts.common.not_available'))
        expect(row.total_display).to eq(I18n.t('receipts.common.not_available'))
      end
    end
  end

  describe '#receipt_review_notes_state' do
    it 'groups blocking reasons and includes review items in the count' do
      review_items = [ instance_double('ReceiptReviewItem'), instance_double('ReceiptReviewItem') ]
      receipt = instance_double(
        Receipt,
        blocking_review_reason_codes: %w[item_name_uncertain tax_detail_mismatch],
        review_items: review_items
      )

      state = helper.receipt_review_notes_state(receipt)

      aggregate_failures do
        expect(state.groups[:ai]).to eq([ 'item_name_uncertain' ])
        expect(state.groups[:amount]).to eq([ 'tax_detail_mismatch' ])
        expect(state.items).to eq(review_items)
        expect(state.count).to eq(4)
      end
    end
  end

  describe '#receipt_warning_notes_state' do
    it 'groups warning reasons and counts grouped reasons' do
      receipt = instance_double(
        Receipt,
        warning_review_reason_codes: %w[ocr_low_confidence item_tax_rate_uncertain]
      )

      state = helper.receipt_warning_notes_state(receipt)

      aggregate_failures do
        expect(state.groups[:ocr]).to eq([ 'ocr_low_confidence' ])
        expect(state.groups[:ai]).to eq([ 'item_tax_rate_uncertain' ])
        expect(state.items).to eq([])
        expect(state.count).to eq(2)
      end
    end
  end
end
