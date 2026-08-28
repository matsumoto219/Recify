require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ReferencePricingSingleStructuredItemGrossPolicy do
  NATIVE_ITEM_LINE_TOTAL_LIMIT = 999_999_999

  def component(path, span_start, span_end)
    {
      source_provider: 'azure_structured',
      source_field_path: path,
      item_index: 0,
      provider_span_start: span_start,
      provider_span_end: span_end
    }
  end

  def candidate
    {
      candidate_id: 'azure_items_0_reference_pricing',
      item_index: 0,
      validation_state: 'ambiguous',
      rejection_reasons: [ 'ambiguous_tax_inclusion' ],
      reference_price: {
        amount: '240',
        evidence: component('documents[0].fields.Items[0].Price', 10, 13)
      },
      reference_quantity: {
        amount: '100',
        unit_code: 'gram',
        unit_status: 'known',
        origin: 'explicit',
        evidence: component('documents[0].fields.Items[0].Price', 14, 18)
      },
      purchased_quantity: {
        amount: '250',
        unit_code: 'gram',
        unit_status: 'known',
        evidence: component('documents[0].fields.Items[0].Quantity', 19, 23)
      },
      reference_price_tax_inclusion: 'unknown',
      tax_inclusion_evidence: nil,
      printed_line_total: {
        amount: '600',
        evidence: component('documents[0].fields.Items[0].TotalPrice', 24, 27)
      },
      corroboration: {
        exact_amount: { numerator: '600', denominator: '1' },
        projected_amount: 600,
        printed_line_total: '600',
        rounding_matches: [ 'floor', 'half_up', 'ceil' ]
      }
    }
  end

  def structural(path, span_start, span_end, source_provider: 'azure_structured')
    {
      source_provider: source_provider,
      source_field_path: path,
      provider_span_start: span_start,
      provider_span_end: span_end
    }
  end

  def line_structural(path, line_index, span_start, span_end, source_provider: 'azure_structured')
    structural(path, span_start, span_end, source_provider: source_provider).merge(
      page_index: 0,
      line_index: line_index,
      string_index_type: 'textElements'
    )
  end

  def evidence
    Ocr::ResponseParser::ReferencePricingSingleStructuredItemGrossEvidenceExtractor::Result.new(
      string_index_type: 'textElements',
      item_parent: structural('documents[0].fields.Items[0]', 0, 30).merge(item_index: 0),
      tax_detail_parent: structural('documents[0].fields.TaxDetails[0]', 40, 55).merge(tax_detail_index: 0),
      tax_description: line_structural(
        'documents[0].fields.TaxDetails[0].Description', 4, 40, 47
      ).merge(tax_detail_index: 0),
      tax_amount: line_structural(
        'documents[0].fields.TaxDetails[0].Amount', 5, 48, 51
      ).merge(tax_detail_index: 0, amount: 54),
      document_tax_total: line_structural(
        'documents[0].fields.TotalTax', 5, 48, 51
      ).merge(amount: 54),
      summary_total: line_structural(
        'pages[0].lines[7]', 7, 65, 68, source_provider: 'azure_document_total'
      ).merge(amount: 600)
    )
  end

  def evaluate(candidate_value: candidate, evidence_value: evidence, **overrides)
    described_class.call(
      candidate: candidate_value,
      item_count: 1,
      retained_item_indexes: [ 0 ],
      summary_gross_evidence: evidence_value,
      adjustment_count: 0,
      discount_count: 0,
      competing_tax_basis_count: 0,
      item_line_total_limit: NATIVE_ITEM_LINE_TOTAL_LIMIT,
      **overrides
    )
  end

  it 'native candidateの唯一の不足がtax inclusionならgrossへ昇格できる' do
    result = evaluate

    expect(result).to have_attributes(
      eligible: true,
      reason: 'eligible',
      reference_price_tax_inclusion: 'gross',
      evidence_kind: 'single_item_receipt_inner_tax_summary',
      candidate_id: 'azure_items_0_reference_pricing'
    )
  end

  it 'implicit per-unit基準数量1をPriceまたはQuantityUnit spanから昇格できる' do
    implicit = candidate.deep_dup
    implicit[:reference_price][:amount] = '2.4'
    implicit[:reference_quantity].merge!(
      amount: '1',
      origin: 'implicit_per_unit',
      evidence: component('documents[0].fields.Items[0].QuantityUnit', 14, 15)
    )

    aggregate_failures do
      expect(evaluate(candidate_value: implicit)).to be_eligible

      price_owned = implicit.deep_dup
      price_owned[:reference_quantity][:evidence] = component(
        'documents[0].fields.Items[0].Price', 14, 15
      )
      expect(evaluate(candidate_value: price_owned)).to be_eligible

      wrong_owner = implicit.deep_dup
      wrong_owner[:reference_quantity][:evidence] = component(
        'documents[0].fields.Items[0].Quantity', 14, 15
      )
      expect(evaluate(candidate_value: wrong_owner)).not_to be_eligible

      non_unit_basis = implicit.deep_dup
      non_unit_basis[:reference_quantity][:amount] = '2'
      expect(evaluate(candidate_value: non_unit_basis)).not_to be_eligible
    end
  end

  it 'candidate identity・state・source completenessの不一致を拒否する' do
    mutations = [
      candidate.merge(candidate_id: 'azure_items_1_reference_pricing'),
      candidate.merge(item_index: 1),
      candidate.merge(validation_state: 'valid'),
      candidate.merge(rejection_reasons: [ 'ambiguous_tax_inclusion', 'ambiguous_reference_expression' ]),
      candidate.deep_dup.tap { |value| value[:reference_price][:amount] = nil },
      candidate.merge(reference_price_tax_inclusion: 'net')
    ]

    mutations.each do |invalid_candidate|
      expect(evaluate(candidate_value: invalid_candidate)).not_to be_eligible
    end
  end

  it 'single raw Item・retained destination・競合なしを必須にする' do
    aggregate_failures do
      expect(evaluate(item_count: 0)).not_to be_eligible
      expect(evaluate(item_count: 2)).not_to be_eligible
      expect(evaluate(retained_item_indexes: [])).not_to be_eligible
      expect(evaluate(retained_item_indexes: [ 0, 1 ])).not_to be_eligible
      expect(evaluate(adjustment_count: 1)).not_to be_eligible
      expect(evaluate(discount_count: 1)).not_to be_eligible
      expect(evaluate(competing_tax_basis_count: 1)).not_to be_eligible
    end
  end

  it 'candidate componentをexact Item parent外から借りない' do
    outside = candidate.deep_dup
    outside[:purchased_quantity][:evidence][:provider_span_end] = 31

    expect(evaluate(candidate_value: outside)).not_to be_eligible
  end

  it 'Amount projection・printed total・summary totalの完全一致を必須にする' do
    printed_mismatch = candidate.deep_dup
    printed_mismatch[:printed_line_total][:amount] = '601'
    corroboration_mismatch = candidate.deep_dup
    corroboration_mismatch[:corroboration][:projected_amount] = 601
    exact_amount_mismatch = candidate.deep_dup
    exact_amount_mismatch[:corroboration][:exact_amount][:numerator] = '601'
    summary_mismatch = evidence.to_h.deep_dup
    summary_mismatch[:summary_total][:amount] = 601

    aggregate_failures do
      expect(evaluate(candidate_value: printed_mismatch)).not_to be_eligible
      expect(evaluate(candidate_value: corroboration_mismatch)).not_to be_eligible
      expect(evaluate(candidate_value: exact_amount_mismatch)).not_to be_eligible
      expect(evaluate(evidence_value: summary_mismatch)).not_to be_eligible
    end
  end

  it 'evidence kind・span association・amount上限の不整合をfail-closedにする' do
    overlapping = evidence.to_h.deep_dup
    overlapping[:tax_detail_parent][:provider_span_start] = 20
    wrong_index = evidence.to_h.deep_dup
    wrong_index[:item_parent][:item_index] = 1

    aggregate_failures do
      expect(evaluate(evidence_value: nil)).not_to be_eligible
      expect(evaluate(evidence_value: overlapping)).not_to be_eligible
      expect(evaluate(evidence_value: wrong_index)).not_to be_eligible
      expect(evaluate(item_line_total_limit: 0)).not_to be_eligible
    end
  end
end
