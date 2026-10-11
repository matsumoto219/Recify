require 'rails_helper'

RSpec.describe 'Item name review resolution' do
  let(:receipt) { create(:receipt, :processing, :with_image) }
  let(:item_review_reasons) { [] }
  let(:item_confidence) { 0.95 }
  let(:ocr_result) do
    {
      success: true,
      raw_text: "検証店\n2026/06/01 12:00\n検証品A 300\n合計 300\n現金",
      lines: [ '検証店', '2026/06/01 12:00', '検証品A 300', '合計 300', '現金' ],
      candidates: {
        store_name: '検証店',
        purchased_at_text: '2026/06/01 12:00',
        country_region: 'JPN',
        total_amount: 300,
        payment_method_text: '現金',
        items: [
          { raw_text: '検証品A', price: 300, quantity: 1, line_total: 300, confidence: item_confidence }
        ],
        payments: [ { method: 'Cash', amount: 300 } ]
      }
    }
  end
  let(:ai_result) do
    {
      success: true,
      needs_review: true,
      review_reasons: [ 'item_name_uncertain' ],
      receipt_attributes: {},
      receipt_items_attributes: [
        {
          index: 0,
          category: 'daily_goods',
          needs_review: true,
          review_reasons: item_review_reasons
        }
      ]
    }
  end

  def finalize_receipt
    run = Receipts::Processing.start(receipt: receipt, source: 'upload').run
    Receipts::Processing.record_ocr_snapshot(run, ocr_result)
    Receipts::Processing.record_ai_normalized_result(run, ai_result)
    Receipts::Processing.record_finalize_decision(
      run,
      Receipts::Processing::Contracts::FinalizeDecision.new(
        finalize_strategy: 'ai_success',
        receipt_attributes: {},
        metadata: {}
      )
    )

    result = Receipts::Processing.run_finalize(run.reload)
    expect(result.next_step).to eq(:done)
    receipt.reload
  end

  shared_examples 'a resolved name with another review reason' do
    it '明示された別項目の確認を維持し、解消済みの商品名reasonだけを解除する' do
      finalize_receipt

      aggregate_failures do
        expect(receipt).to have_attributes(status: 'review_needed', total_amount: 300)
        expect(receipt.review_reasons).not_to include('item_name_uncertain')
        expect(receipt.receipt_items.sole).to have_attributes(
          raw_text: '検証品A',
          suggested_name: '検証品A',
          line_total: 300,
          review_reasons: item_review_reasons
        )
      end
    end
  end

  context '計算方式だけに明示的な確認理由がある場合' do
    let(:item_review_reasons) { [ 'item_pricing_mode_uncertain' ] }

    include_examples 'a resolved name with another review reason'
  end

  context '分類だけに明示的な確認理由がある場合' do
    let(:item_review_reasons) { [ 'item_category_uncertain' ] }

    include_examples 'a resolved name with another review reason'
  end

  context '数量だけに明示的な確認理由がある場合' do
    let(:item_review_reasons) { [ 'item_quantity_uncertain' ] }

    include_examples 'a resolved name with another review reason'
  end

  context '税率だけに明示的な確認理由がある場合' do
    let(:item_review_reasons) { [ 'item_tax_rate_uncertain' ] }

    include_examples 'a resolved name with another review reason'
  end

  context '商品名にも明示的な確認理由がある場合' do
    let(:item_review_reasons) { %w[item_name_uncertain item_quantity_uncertain] }

    it '商品名の確認理由を残す' do
      finalize_receipt

      expect(receipt.review_reasons).to include('item_name_uncertain')
      expect(receipt.receipt_items.sole.review_reasons).to eq(item_review_reasons)
    end
  end

  context '数量の確認理由があってもOCR confidenceが低い場合' do
    let(:item_review_reasons) { [ 'item_quantity_uncertain' ] }
    let(:item_confidence) { 0.3 }

    it '商品名の確認理由を解除しない' do
      finalize_receipt

      expect(receipt.review_reasons).to include('item_name_uncertain')
      expect(receipt.status).to eq('review_needed')
    end
  end

  describe '未解消の名称根拠' do
    let(:step) do
      Receipts::Processing::Pipeline::FinalizeStep.new(receipt: build(:receipt), decision: nil)
    end
    let(:item) do
      {
        raw_text: '検証品A', category: 'daily_goods', line_total: 300,
        needs_review: true, confidence: 0.95, review_reasons: []
      }
    end

    def names_resolved?(item:, amount_result: {})
      step.send(:item_names_resolved?, { receipt_items_attributes: [ item ] }, amount_result)
    end

    it '明示的な理由のないgeneric reviewは商品名reasonの解除根拠にしない' do
      expect(names_resolved?(item: item)).to be(false)
    end

    it '名称欠損を別項目の確認理由で解消扱いにしない' do
      item.merge!(raw_text: nil, review_reasons: [ 'item_quantity_uncertain' ])

      expect(names_resolved?(item: item)).to be(false)
    end

    it '明細合計の不一致があれば商品名reasonを解除しない' do
      item[:review_reasons] = [ 'item_quantity_uncertain' ]

      expect(names_resolved?(item: item, amount_result: { blocking_inconsistencies: [ 'item_total_mismatch' ] })).to be(false)
    end

    it '別項目と特定できないreasonを名称解消の根拠にしない' do
      item[:review_reasons] = [ 'ocr_low_confidence' ]

      expect(names_resolved?(item: item)).to be(false)
    end
  end
end
