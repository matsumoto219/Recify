require 'rails_helper'

RSpec.describe '金額source欠損明細の限定review' do
  def build_missing_source_item(**attributes)
    item = {
      raw_text: '検証品',
      category: 'other',
      quantity: 2,
      quantity_unit_code: 'each',
      quantity_unit_status: 'known',
      tax_rate: BigDecimal('0.27'),
      needs_review: false,
      review_reasons: []
    }.merge(attributes)

    Analysis.build_receipt_params(
      ocr_result: { candidates: { country_region: 'JPN', items: [ item ] }, lines: [] }
    ).fetch(:receipt_items_attributes).sole
  end

  it '金額sourceがない場合だけ計算方式欄を要確認にし金額を発明しない' do
    item = build_missing_source_item

    expect(item).to include(price: nil, line_total: nil, original_line_total: nil, needs_review: true)
    expect(item[:review_reasons]).to eq([ 'item_pricing_mode_uncertain' ])
    expect(item[:pricing_source_kind]).to be_nil
  end

  it '明示された0円と非0円の明細金額を欠損扱いしない' do
    [ 0, 257 ].each do |amount|
      item = build_missing_source_item(line_total: amount)

      expect(item[:review_reasons]).not_to include('item_pricing_mode_uncertain')
    end
  end

  it '印字合計なしでも0円を含む単価と数量があれば欠損reviewを足さない' do
    [ 0, 257 ].each do |price|
      item = build_missing_source_item(price: price)

      expect(item[:review_reasons]).not_to include('item_pricing_mode_uncertain')
    end
  end

  it '既存の別fieldのreview理由を解除しない' do
    item = build_missing_source_item(review_reasons: [ 'item_name_uncertain' ])

    expect(item[:review_reasons]).to contain_exactly('item_name_uncertain', 'item_pricing_mode_uncertain')
  end

  it 'Finalize後も金額欠損の確認理由を保ちlegacyの0円をexplicit authorityへ昇格しない' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = Receipts::Processing.start(receipt:, source: 'upload').run
    Receipts::Processing.record_ocr_snapshot(
      run,
      {
        success: true,
        lines: [],
        candidates: {
          country_region: 'JPN',
          total_amount: 0,
          items: [ build_missing_source_item.merge(needs_review: false, review_reasons: []) ]
        }
      }
    )
    decision = Receipts::Processing::Contracts::FinalizeDecision.new(
      finalize_strategy: 'ocr_only',
      error_code: nil,
      error_message: nil,
      receipt_attributes: {},
      ocr_result: nil,
      ai_result: nil,
      metadata: {}
    )
    Receipts::Processing.record_finalize_decision(run, decision)

    Receipts::Processing.run_finalize(run.reload)
    item = receipt.reload.receipt_items.sole

    expect(item).to have_attributes(pricing_source_kind: nil, line_total: 0, original_line_total: 0, needs_review: true)
    expect(item.review_reasons).to include('item_pricing_mode_uncertain')
  end
end
