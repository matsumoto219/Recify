require 'rails_helper'

RSpec.describe 'Analysis payment method evidence protection' do
  let(:proof) do
    {
      source_kind: 'azure_same_row', method: 'e_money', page_index: 0,
      label_line_index: 0, method_line_index: 1,
      label_path: 'pages[0].lines[0]', method_path: 'pages[0].lines[1]',
      label_span: { offset: 0, length: 2 }, method_span: { offset: 3, length: 2 },
      string_index_type: 'textElements'
    }
  end
  let(:ocr) do
    {
      lines: [ '売上', 'id', '検証品 600', '合計 600' ],
      candidates: {
        store_name: '検証店舗', purchased_at_text: '2026/05/01 12:00', currency_code: 'JPY',
        total_amount: 600, tax_amount: 0, payment_method_text: 'iD', payment_method_evidence: proof,
        items: [ { raw_text: '検証品', quantity: 1, price: 600, line_total: 600, tax_rate: 0 } ],
        payments: [], tax_details: []
      }
    }
  end
  let(:ai) { { receipt_attributes: { 'payment_method' => 'credit_card' }, receipt_items_attributes: [] } }

  def without_proof(value)
    value.deep_dup.tap { |copy| copy[:candidates].delete(:payment_method_evidence) }
  end

  def build(value = ocr)
    Analysis.build_receipt_params(ocr_result: value, ai_result: ai)
  end

  it 'protects a uniquely evidenced method without changing any amount, payment row or review reason' do
    baseline = build(without_proof(ocr))
    result = build

    aggregate_failures do
      expect(result.dig(:receipt_attributes, :payment_method)).to eq('e_money')
      expect(result[:receipt_payments_attributes]).to be_empty
      expect(result.deep_merge(receipt_attributes: { payment_method: 'credit_card' })).to eq(baseline)
      expect(result.dig(:receipt_attributes, :total_amount)).to eq(600)
      expect(result[:receipt_items_attributes]).to eq(baseline[:receipt_items_attributes])
    end
  end

  it 'retains the existing AI-first behavior for an old snapshot without proof' do
    old = without_proof(ocr).merge(schema_version: 'receipt_analysis_run_ocr_result_v1', truncated: { lines: false, items: false, payments: false })

    expect(build(old).dig(:receipt_attributes, :payment_method)).to eq('credit_card')
  end

  it 'accepts current snapshots only with explicit completeness flags' do
    current = ocr.merge(schema_version: 'receipt_analysis_run_ocr_result_v1', truncated: { lines: false, items: false, payments: false })

    expect(build(current).dig(:receipt_attributes, :payment_method)).to eq('e_money')
  end

  it 'keeps unrelated exact item Description evidence independent of the payment proof' do
    ocr[:candidates][:items].first[:description_source_refs] = [ { line_index: 2, character_offset: 0, character_length: 3 } ]

    expect(build.dig(:receipt_attributes, :payment_method)).to eq('e_money')
  end

  it 'protects only the method while preserving financial ambiguity from unrelated numeric metadata' do
    ocr[:lines] << 'trace 123456'
    baseline = build(without_proof(ocr))
    result = build

    aggregate_failures do
      expect(baseline.dig(:payment_evidence, :settlement, :observed_ambiguity)).to be(true)
      expect(result.dig(:payment_evidence, :settlement, :observed_ambiguity)).to be(true)
      expect(result.dig(:receipt_attributes, :payment_method)).to eq('e_money')
      expect(result.deep_merge(receipt_attributes: { payment_method: 'credit_card' })).to eq(baseline)
    end
  end

  {
    'unsupported proof' => ->(value) { value[:candidates][:payment_method_evidence][:string_index_type] = 'unknown' },
    'multiple pairs' => ->(value) { value[:lines] += [ '支払方法', 'id' ] },
    'truncated lines' => ->(value) { value[:truncated] = { lines: true } },
    'truncated items' => ->(value) { value[:truncated] = { items: true } },
    'truncated payments' => ->(value) { value[:truncated] = { payments: true } },
    'malformed truncation flag' => ->(value) { value[:truncated] = { lines: 'false' } },
    'malformed truncation container' => ->(value) { value[:truncated] = [] },
    'snapshot missing completeness' => ->(value) { value[:schema_version] = 'receipt_analysis_run_ocr_result_v1' },
    'unknown snapshot version' => ->(value) { value[:schema_version] = 'unknown' },
    'competing payment row' => ->(value) { value[:candidates][:payments] = [ { method: '現金', amount: 600 } ] },
    'agreeing payment row outside this subset' => ->(value) { value[:candidates][:payments] = [ { method: 'iD', amount: 600 } ] },
    'unclassified transaction' => ->(value) { value[:lines] << '未分類の支払 600' },
    'refund evidence' => ->(value) { value[:lines] << '返金 600' },
    'zero use of the proven method' => ->(value) { value[:lines] << 'iD 0円' },
    'item-owned source line' => ->(value) { value[:candidates][:items].first[:source_line_index] = 1 },
    'item Description span' => ->(value) { value[:candidates][:items].first[:description_source_refs] = [ { line_index: 1, character_offset: 0, character_length: 2 } ] },
    'invalid item Description proof' => ->(value) { value[:candidates][:items].first[:description_source_refs] = 'invalid' },
    'item Description outside its line' => ->(value) { value[:candidates][:items].first[:description_source_refs] = [ { line_index: 2, character_offset: 500, character_length: 3 } ] },
    'measurement-owned block' => ->(value) { value[:candidates][:reference_pricing_block_line_indexes] = [ 0, 1 ] }
  }.each do |description, change|
    it "does not override existing behavior for #{description}" do
      changed = ocr.deep_dup
      change.call(changed)

      expect(build(changed)).to eq(build(without_proof(changed)))
    end
  end
end
