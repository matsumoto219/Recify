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
      expect(result.items).to eq(items)
      expect(result.adjustments).to eq(adjustments)
      expect(result.payments).to eq(payments)
      expect(result.tax_details).to eq(tax_details)
      expect(result.facts.map(&:owner)).to eq(%i[item receipt_adjustment payment tax_detail])
      expect(result.facts.second).to have_attributes(
        fact_type: :purchase_adjustment,
        effect_scope: :purchase_total,
        action: :persist
      )
      expect(result.facts.second.source_refs.first).to have_attributes(
        provider: :ocr_line,
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

  it 'structured fieldのsource参照をfactだけに保持して保存attributesから除外する' do
    evidence_index = Analysis::SourceEvidenceIndex.call(
      lines: [ '商品A 100円' ],
      money_pattern: /[¥￥]?\d+(?:円)?/,
      profile: ReceiptAnalysisProfiles.default
    )
    item = {
      raw_text: '商品A',
      line_total: 100,
      source_provider: 'azure_structured',
      source_field_path: 'documents[0].fields.Items[0].TotalPrice',
      source_line_index: 0,
      source_span_start: 4,
      source_span_end: 8
    }

    result = described_class.call(
      items: [ item ],
      adjustments: [],
      payments: [],
      tax_details: [],
      review_reasons: [],
      evidence_index: evidence_index
    )

    aggregate_failures do
      expect(result.facts.first.source_refs.first).to have_attributes(
        provider: :azure_structured,
        field_path: 'documents[0].fields.Items[0].TotalPrice',
        line_index: 0,
        span_start: 4,
        span_end: 8,
        amount_token: 100
      )
      expect(result.items).to eq([ { raw_text: '商品A', line_total: 100 } ])
    end
  end

  it 'owner ruleでpurchase adjustmentとpayment adjustmentのeffect scopeを分離する' do
    adjustments = [
      {
        kind: 'coupon',
        sign: 'discount',
        amount: 100,
        source: 'ocr',
        source_text: 'クーポン値引 -100円',
        source_line_index: 0
      },
      {
        kind: 'point_usage',
        sign: 'discount',
        amount: 200,
        source: 'ocr',
        source_text: 'ポイント利用 -200円',
        source_line_index: 1
      },
      {
        kind: 'receipt_discount',
        sign: 'discount',
        amount: 22,
        source: 'ocr',
        source_text: 'キャッシュレス還元額 -22円',
        source_line_index: 2
      }
    ]
    evidence_index = Analysis::SourceEvidenceIndex.call(
      lines: adjustments.map { |adjustment| adjustment[:source_text] },
      money_pattern: /[▲△\-−]?\s*[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:円)?/,
      profile: ReceiptAnalysisProfiles.default
    )

    result = described_class.call(
      items: [],
      adjustments: adjustments,
      payments: [],
      tax_details: [],
      review_reasons: [],
      evidence_index: evidence_index
    )

    aggregate_failures do
      expect(result.facts.map(&:fact_type)).to eq(%i[purchase_adjustment payment_adjustment payment_adjustment])
      expect(result.facts.map(&:effect_scope)).to eq(%i[purchase_total final_payment_total final_payment_total])
      expect(result.adjustments).to eq(adjustments)
    end
  end

  describe 'discount token ownership' do
    let(:profile) { ReceiptAnalysisProfiles.default }
    let(:lines) { [ '例示品 600円', '値引 -120円', 'クーポン -120円' ] }
    let(:evidence_index) do
      Analysis::SourceEvidenceIndex.call(
        lines: lines,
        money_pattern: profile.analysis_adjustment_amount_candidate_pattern,
        profile: profile
      )
    end

    def discount_reference(line_index)
      token = evidence_index.fetch(line_index).fetch(:tokens).find { |entry| entry[:kind] == :money }
      {
        source_line_index: line_index,
        source_span_start: token.fetch(:span_start),
        source_span_end: token.fetch(:span_end),
        amount: token.fetch(:amount)
      }
    end

    def resolve_discount_facts(items:, adjustments:)
      described_class.call(
        items: items,
        adjustments: adjustments,
        payments: [],
        tax_details: [],
        review_reasons: [],
        evidence_index: evidence_index,
        profile: profile
      )
    end

    def adjustment_at(index, **attributes)
      {
        kind: 'receipt_discount',
        sign: 'discount',
        amount: 120,
        source: 'ocr',
        source_text: lines.fetch(index),
        source_line_index: index
      }.merge(attributes)
    end

    it 'adds item discount ownership without replacing the main total and preserves a separate same-amount coupon' do
      result = resolve_discount_facts(
        items: [
          {
            raw_text: '例示品',
            line_total: 600,
            source_line_index: 0,
            discount_amount: 120,
            discount_source_refs: [ discount_reference(1) ]
          }
        ],
        adjustments: [ adjustment_at(1), adjustment_at(2, kind: 'coupon') ]
      )

      aggregate_failures do
        expect(result.items).to eq([ { raw_text: '例示品', line_total: 600, discount_amount: 120 } ])
        expect(result.facts.first.source_refs.map(&:line_index)).to eq([ 0, 1 ])
        expect(result.adjustments).to contain_exactly(include(kind: 'coupon', source_line_index: 2, amount: 120))
        expect(result.diagnostics).to include(include(code: :item_owner_wins))
      end
    end

    it 'keeps informational per-unit discount tokens item-owned without adding their amounts' do
      lines.replace([ '例示品 600円', '値引 -120円', '(1個 -60円)' ])
      result = resolve_discount_facts(
        items: [
          {
            raw_text: '例示品',
            line_total: 480,
            discount_amount: 120,
            discount_source_refs: [ discount_reference(1), discount_reference(2) ]
          }
        ],
        adjustments: [ adjustment_at(1), adjustment_at(2, amount: 60) ]
      )

      aggregate_failures do
        expect(result.items).to contain_exactly(include(line_total: 480, discount_amount: 120))
        expect(result.adjustments).to be_empty
      end
    end

    it 'does not borrow a nearby item discount rate to discard an independent same-amount coupon' do
      lines.replace([ '例示品 600円', '20% 割引 -120円', '値引 -120円' ])
      result = resolve_discount_facts(
        items: [
          {
            raw_text: '例示品',
            line_total: 480,
            discount_amount: 120,
            discount_rate: 0.2,
            discount_source_refs: [ discount_reference(1) ]
          }
        ],
        adjustments: [ adjustment_at(1), adjustment_at(2, kind: 'coupon') ]
      )

      expect(result.adjustments).to contain_exactly(include(kind: 'coupon', source_line_index: 2, amount: 120))
    end

    it 'uses signed evidence when a positive and a negative token have the same amount nearby' do
      lines.replace([ '例示品 120円', '値引 -120円' ])
      result = resolve_discount_facts(items: [], adjustments: [ adjustment_at(1) ])

      expect(result.facts.sole.source_refs.sole.line_index).to eq(1)
    end

    it 'deduplicates OCR and AI proposals by the negative token instead of source text casing' do
      lines.replace([ '例示品 120円', 'Discount -120円' ])
      result = resolve_discount_facts(
        items: [],
        adjustments: [ adjustment_at(1), adjustment_at(1, source: 'ai', source_text: 'discount -120円') ]
      )

      expect(result.adjustments).to contain_exactly(include(amount: 120, source: 'ai'))
    end

    it 'marks indexed adjustments with ambiguous negative tokens for review' do
      lines.replace([ '値引 -120円 -120円' ])
      result = resolve_discount_facts(items: [], adjustments: [ adjustment_at(0) ])

      aggregate_failures do
        expect(result.facts.sole.source_refs).to be_empty
        expect(result.adjustments).to contain_exactly(include(needs_review: true, review_reasons: [ 'adjustment_uncertain' ]))
        expect(result.review_reasons).to include('adjustment_uncertain')
        expect(Analysis::OwnershipConsistencyGuard.contract_for(result)[:adjustment_review_required_count]).to eq(1)
      end
    end

    it 'preserves the legacy behavior of an unindexed adjustment without evidence' do
      adjustment = { kind: 'coupon', sign: 'discount', amount: 120, source: 'ocr', label: 'クーポン' }
      result = resolve_discount_facts(items: [], adjustments: [ adjustment ])

      expect(result.adjustments).to eq([ adjustment ])
    end

    it 'rejects all discount references if any token span or amount is malformed' do
      result = resolve_discount_facts(
        items: [
          {
            raw_text: '例示品',
            line_total: 600,
            source_line_index: 0,
            discount_source_refs: [ discount_reference(1), discount_reference(2).merge(amount: 119) ]
          }
        ],
        adjustments: [ adjustment_at(1) ]
      )

      aggregate_failures do
        expect(result.facts.first.source_refs.map(&:line_index)).to eq([ 0 ])
        expect(result.adjustments).to contain_exactly(include(amount: 120))
        expect(result.items.sole).not_to have_key(:discount_source_refs)
      end
    end
  end

  describe 'consecutive adjustment label and amount lines' do
    let(:profile) { ReceiptAnalysisProfiles.default }
    let(:lines) { [ 'サービス料10%', '120円', '深夜料金10%', '120円' ] }
    let(:evidence_index) do
      Analysis::SourceEvidenceIndex.call(
        lines: lines,
        money_pattern: profile.analysis_adjustment_amount_candidate_pattern,
        profile: profile
      )
    end

    def charge_at(index, kind: 'late_night_charge', **attributes)
      {
        kind: kind,
        sign: 'surcharge',
        amount: 120,
        source: 'ocr',
        source_text: lines.fetch(index),
        source_line_index: index,
        needs_review: false,
        review_reasons: []
      }.merge(attributes)
    end

    def resolve_charges(adjustments = [ charge_at(0, kind: 'service_charge'), charge_at(2) ], items: [])
      described_class.call(
        items: items,
        adjustments: adjustments,
        payments: [],
        tax_details: [],
        review_reasons: [],
        evidence_index: evidence_index,
        profile: profile
      )
    end

    it 'binds equal amounts to their separate label blocks without changing label indexes' do
      result = resolve_charges

      aggregate_failures do
        expect(result.adjustments.map { |adjustment| adjustment[:source_line_index] }).to eq([ 0, 2 ])
        expect(result.adjustments).to all(include(needs_review: false, review_reasons: []))
        expect(result.facts.map { |fact| fact.source_refs.sole.line_index }).to eq([ 1, 3 ])
        expect(result.facts.map { |fact| fact.source_refs.sole.strong_identity }.uniq.size).to eq(2)
      end
    end

    it 'keeps three consecutive same-amount charges distinct' do
      lines.concat([ '配送料', '120円' ])
      result = resolve_charges([
        charge_at(0, kind: 'service_charge'),
        charge_at(2),
        charge_at(4, kind: 'delivery_fee')
      ])

      aggregate_failures do
        expect(result.adjustments.size).to eq(3)
        expect(result.adjustments).to all(include(needs_review: false, review_reasons: []))
        expect(result.facts.map { |fact| fact.source_refs.sole.line_index }).to eq([ 1, 3, 5 ])
      end
    end

    it 'does not depend on the order of charge labels or proposals' do
      lines.replace([ '深夜料金10%', '120円', 'サービス料10%', '120円' ])
      result = resolve_charges([ charge_at(2, kind: 'service_charge'), charge_at(0) ])

      aggregate_failures do
        expect(result.adjustments).to all(include(needs_review: false, review_reasons: []))
        expect(result.facts.map { |fact| fact.source_refs.sole.line_index }).to eq([ 3, 1 ])
      end
    end

    it 'deduplicates AI and OCR only when they resolve to the same physical amount' do
      result = resolve_charges([
        charge_at(0, kind: 'service_charge'),
        charge_at(2),
        charge_at(2, source: 'ai')
      ])

      aggregate_failures do
        expect(result.adjustments).to contain_exactly(
          include(kind: 'service_charge', source: 'ocr', source_line_index: 0, needs_review: false),
          include(kind: 'late_night_charge', source: 'ai', source_line_index: 2, needs_review: false)
        )
        expect(result.diagnostics).to include(include(code: :same_source_duplicate))
      end
    end

    it 'keeps amount-only bare numbers bound to their own charge block' do
      lines[1] = '120'
      lines[3] = '120'
      result = resolve_charges

      expect(result.facts.map { |fact| fact.source_refs.sole.line_index }).to eq([ 1, 3 ])
    end

    it 'preserves unsigned discounts with distinct amounts and explicit discount labels' do
      lines.replace([ 'クーポン', '120円', '値引', '230円' ])
      result = resolve_charges([
        charge_at(0, kind: 'coupon', sign: 'discount'),
        charge_at(2, kind: 'receipt_discount', sign: 'discount', amount: 230)
      ])

      aggregate_failures do
        expect(result.adjustments).to all(include(sign: 'discount', needs_review: false, review_reasons: []))
        expect(result.adjustments.map { |adjustment| adjustment[:amount] }).to eq([ 120, 230 ])
        expect(result.facts.map { |fact| fact.source_refs.sole.line_index }).to eq([ 1, 3 ])
      end
    end

    it 'keeps equal unsigned discounts bound to their distinct physical blocks' do
      lines.replace([ 'クーポン', '120円', '値引', '120円' ])
      result = resolve_charges([
        charge_at(0, kind: 'coupon', sign: 'discount'),
        charge_at(2, kind: 'receipt_discount', sign: 'discount')
      ])

      aggregate_failures do
        expect(result.adjustments.size).to eq(2)
        expect(result.adjustments).to all(include(sign: 'discount', needs_review: false, review_reasons: []))
        expect(result.facts.map { |fact| fact.source_refs.sole.line_index }).to eq([ 1, 3 ])
      end
    end

    it 'keeps negative discount tokens bound to their distinct physical blocks' do
      lines.replace([ 'クーポン', '-120円', '値引', '-120円' ])
      result = resolve_charges([
        charge_at(0, kind: 'coupon', sign: 'discount'),
        charge_at(2, kind: 'receipt_discount', sign: 'discount')
      ])

      aggregate_failures do
        expect(result.adjustments).to all(include(sign: 'discount', needs_review: false, review_reasons: []))
        expect(result.facts.map { |fact| fact.source_refs.sole.line_index }).to eq([ 1, 3 ])
      end
    end

    it 'does not use the preceding charge amount when the current amount differs' do
      lines[3] = '121円'
      result = resolve_charges([ charge_at(2) ])

      aggregate_failures do
        expect(result.facts.sole.source_refs).to be_empty
        expect(result.adjustments).to contain_exactly(include(needs_review: true, review_reasons: [ 'adjustment_uncertain' ]))
      end
    end

    [ '', '120円 120円', '別明細 120円', '0円', '-120円' ].each do |amount_line|
      it "does not bind an invalid current amount line #{amount_line.inspect}" do
        lines[3] = amount_line
        result = resolve_charges([ charge_at(2) ])

        aggregate_failures do
          expect(result.facts.sole.source_refs).to be_empty
          expect(result.adjustments).to contain_exactly(include(needs_review: true, review_reasons: [ 'adjustment_uncertain' ]))
        end
      end
    end

    [ { source_span_start: 0, source_span_end: 4 }, { source_span_start: -1 }, { source_span_end: 'invalid' } ].each do |span|
      it "does not replace invalid explicit span #{span.inspect} with a neighboring amount" do
        result = resolve_charges([ charge_at(2, **span) ])

        aggregate_failures do
          expect(result.facts.sole.source_refs).to be_empty
          expect(result.adjustments).to contain_exactly(include(needs_review: true, review_reasons: [ 'adjustment_uncertain' ]))
        end
      end
    end

    it 'does not choose the next amount when the previous amount has no distinct adjustment label' do
      lines[0] = 'その他の記載'
      result = resolve_charges([ charge_at(2) ])

      expect(result.facts.sole.source_refs).to be_empty
    end

    it 'does not partition a preceding line that contains another amount beside its label' do
      lines[0] = 'サービス料 120円'
      result = resolve_charges([ charge_at(2) ])

      expect(result.facts.sole.source_refs).to be_empty
    end

    it 'does not treat multiple tokens in the preceding amount line as a separate block' do
      lines[1] = '120円 120円'
      result = resolve_charges([ charge_at(2) ])

      expect(result.facts.sole.source_refs).to be_empty
    end

    it 'does not apply adjustment block association to item facts' do
      result = resolve_charges([], items: [ { raw_text: lines[2], line_total: 120, source_line_index: 2 } ])

      expect(result.facts.sole.source_refs).to be_empty
    end

    it 'uses the injected profile label patterns rather than fixed receipt vocabulary' do
      allow(profile).to receive(:ocr_adjustment_surcharge_label_pattern).and_return(/CHARGE_[AB]/)
      lines.replace([ 'CHARGE_A', '120円', 'CHARGE_B', '120円' ])
      result = resolve_charges([ charge_at(2) ])

      expect(result.facts.sole.source_refs.sole.line_index).to eq(3)
    end

    it 'does not retain Japanese label matching when the injected patterns are replaced' do
      allow(profile).to receive(:ocr_adjustment_surcharge_label_pattern).and_return(/CHARGE_[AB]/)
      allow(profile).to receive(:ocr_adjustment_discount_label_pattern).and_return(/DISCOUNT_[AB]/)
      result = resolve_charges([ charge_at(2) ])

      expect(result.facts.sole.source_refs).to be_empty
    end
  end
end
