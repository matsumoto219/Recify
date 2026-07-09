require 'rails_helper'

RSpec.describe Analysis::ReceiptFactOwnershipResolver do
  it '既存の保存attributesを変えずにowner factへ写像する' do
    items = [ { raw_text: '商品A', line_total: 1_000, tax_rate: 0.1 } ]
    adjustments = [
      {
        kind: 'coupon',
        sign: 'discount',
        amount: 100,
        tax_rate: 0.1,
        source: 'ocr',
        source_text: 'クーポン -100',
        source_line_index: 1
      }
    ]
    payments = [ { method: 'cash', amount: 900 } ]
    tax_details = [ { rate: 0.1, net_amount: 818, amount: 82 } ]
    evidence_index = Analysis::SourceEvidenceIndex.call(
      lines: [ '商品A 1,000円', 'クーポン -100', '現金 900円' ],
      money_pattern: /[▲△\-−]?\s*[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:円)?/,
      profile: ReceiptAnalysisProfiles.default
    )

    result = described_class.call(
      items: items,
      adjustments: adjustments,
      payments: payments,
      tax_details: tax_details,
      review_reasons: [],
      evidence_index: evidence_index
    )

    aggregate_failures do
      expect(result.items).to equal(items)
      expect(result.adjustments).to equal(adjustments)
      expect(result.payments).to equal(payments)
      expect(result.tax_details).to equal(tax_details)
      expect(result.facts.map(&:owner)).to eq(%i[item receipt_adjustment payment tax_detail])
      expect(result.facts.second).to have_attributes(
        fact_type: :purchase_adjustment,
        effect_scope: :purchase_total,
        action: :persist
      )
      expect(result.facts.second.source_refs.first).to have_attributes(
        provider: 'ocr',
        line_index: 1,
        amount_token: 100,
        amount_token_kind: :money
      )
    end
  end

  it 'ReceiptBuildParamsServiceから1回だけ呼ばれる' do
    allow(described_class).to receive(:call).and_call_original

    Analysis::ReceiptBuildParamsService.call(
      ocr_result: {
        lines: [ 'サンプル店', '商品A 100円', '合計 100円' ],
        candidates: {
          store_name: 'サンプル店',
          total_amount: 100,
          items: [ { raw_text: '商品A', line_total: 100 } ],
          payments: [],
          tax_details: [],
          adjustment_candidates: []
        }
      },
      ai_result: nil
    )

    expect(described_class).to have_received(:call).once
  end
end
