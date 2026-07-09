require 'rails_helper'

RSpec.describe Analysis::AdjustmentEvidenceValidator do
  let(:profile) { ReceiptAnalysisProfiles.default }
  let(:lines) { [ '商品A 100円', '10%対象 91円 税 9円', '現金 100円', 'クーポン -10円' ] }
  let(:evidence_index) do
    Analysis::SourceEvidenceIndex.call(
      lines: lines,
      money_pattern: /[▲△\-−]?\s*[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:円)?/,
      profile: profile
    )
  end
  let(:items) { [ { raw_text: '商品A 100円', line_total: 100 } ] }
  let(:payments) { [ { method: 'cash', amount: 100 } ] }
  let(:tax_details) { [ { description: '10%対象', net_amount: 91, amount: 9, rate: 0.1 } ] }

  def validate(proposal, source: 'ai')
    described_class.call(
      proposal: proposal,
      source: source,
      lines: lines,
      evidence_index: evidence_index,
      items: items,
      payments: payments,
      tax_details: tax_details,
      profile: profile
    )
  end

  it 'source line indexの欠落・範囲外・source text不一致を例外にせずrejectする' do
    aggregate_failures do
      expect(validate({ kind: 'coupon', amount: 10, sign: 'discount', source_text: 'クーポン -10円' })).to have_attributes(
        status: :rejected,
        reason: :source_line_index_missing,
        review_required: true
      )
      expect(validate({ kind: 'coupon', amount: 10, sign: 'discount', source_text: 'クーポン -10円', source_line_index: 99 })).to have_attributes(
        status: :rejected,
        reason: :source_line_index_out_of_range
      )
      expect(validate({ kind: 'coupon', amount: 10, sign: 'discount', source_text: '別の行', source_line_index: 3 })).to have_attributes(
        status: :rejected,
        reason: :source_text_mismatch
      )
    end
  end

  it '商品行・税詳細行・支払行をpurchase adjustmentの根拠にしない' do
    aggregate_failures do
      expect(validate({ kind: 'coupon', amount: 100, sign: 'discount', source_text: '商品A 100円', source_line_index: 0 })).to have_attributes(
        status: :rejected,
        reason: :item_owned,
        review_required: false
      )
      expect(validate({ kind: 'coupon', amount: 9, sign: 'discount', source_text: '10%対象 91円 税 9円', source_line_index: 1 })).to have_attributes(
        status: :rejected,
        reason: :tax_detail_owned
      )
      expect(validate({ kind: 'coupon', amount: 100, sign: 'discount', source_text: '現金 100円', source_line_index: 2 })).to have_attributes(
        status: :rejected,
        reason: :payment_owned
      )
    end
  end

  it 'OCR根拠に結びつく明示的なadjustmentをacceptする' do
    result = validate(
      { kind: 'coupon', amount: 10, sign: 'discount', source_text: 'クーポン -10円', source_line_index: 3 },
      source: 'ocr'
    )

    expect(result).to be_accepted
  end
end
