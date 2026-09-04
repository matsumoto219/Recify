require 'rails_helper'

RSpec.describe Analysis::AdjustmentEvidenceValidator do
  let(:profile) { ReceiptAnalysisProfiles.default }
  let(:lines) { [ '商品A 100円', '10%対象 91円 税 9円', '現金 100円', 'クーポン -10円' ] }
  let(:items) { [ { raw_text: '商品A 100円', line_total: 100 } ] }
  let(:payments) { [ { method: 'cash', amount: 100 } ] }
  let(:tax_details) { [ { description: '10%対象', net_amount: 91, amount: 9, rate: 0.1 } ] }

  def validate(proposal, source: 'ai', source_lines: lines, profile: self.profile)
    described_class.call(
      proposal: proposal,
      source: source,
      lines: source_lines,
      evidence_index: Analysis::SourceEvidenceIndex.call(
        lines: source_lines,
        money_pattern: /[▲△\-−]?\s*[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:円)?/,
        profile: profile
      ),
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

  it '単位当たりの販促注記はOCR source lineを根拠にreviewなしでrejectする' do
    aggregate_failures do
      expect(validate(
        {
          kind: 'receipt_discount',
          label: '値引',
          amount: 3,
          sign: 'discount',
          source_text: '会員値引 3円/L引',
          source_line_index: 0
        },
        source_lines: [ '会員値引 3円/L引' ]
      )).to have_attributes(
        status: :rejected,
        reason: :per_unit_discount_note,
        review_required: false
      )
      expect(validate(
        {
          kind: 'receipt_discount',
          amount: 3,
          sign: 'discount',
          source_text: '3円/L引き',
          source_line_index: 0
        },
        source_lines: [ '3円/L引き' ]
      )).to have_attributes(
        status: :rejected,
        reason: :per_unit_discount_note,
        review_required: false
      )
    end
  end

  it 'AI labelではなくOCR source lineだけで単位当たり注記を判定する' do
    absolute_discount = validate(
      {
        kind: 'receipt_discount',
        label: '会員値引 3円/L引',
        amount: 3,
        sign: 'discount',
        source_text: '値引 3円',
        source_line_index: 0
      },
      source_lines: [ '値引 3円' ]
    )
    ordinary_unit_price = validate(
      {
        kind: 'receipt_discount',
        amount: 160,
        sign: 'discount',
        source_text: '単価 160円/L',
        source_line_index: 0
      },
      source_lines: [ '単価 160円/L' ]
    )

    aggregate_failures do
      expect(absolute_discount).to be_accepted
      expect(ordinary_unit_price).to have_attributes(
        status: :rejected,
        reason: :discount_ownership_uncertain,
        review_required: true
      )
    end
  end

  it 'injected profileのpatternを使い日本語表現をshared validatorへhardcodeしない' do
    allow(profile).to receive(:analysis_per_unit_discount_note_pattern).and_return(/\AUNIT_PROMO\z/)

    injected_match = validate(
      {
        kind: 'receipt_discount',
        amount: 3,
        sign: 'discount',
        source_text: 'UNIT_PROMO',
        source_line_index: 0
      },
      source_lines: [ 'UNIT_PROMO' ]
    )
    japanese_non_match = validate(
      {
        kind: 'receipt_discount',
        amount: 3,
        sign: 'discount',
        source_text: '会員値引 3円/L引',
        source_line_index: 0
      },
      source_lines: [ '会員値引 3円/L引' ]
    )

    aggregate_failures do
      expect(injected_match).to have_attributes(
        status: :rejected,
        reason: :per_unit_discount_note,
        review_required: false
      )
      expect(japanese_non_match).to be_accepted
    end
  end
end
