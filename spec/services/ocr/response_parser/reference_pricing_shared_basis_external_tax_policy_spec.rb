require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ReferencePricingSharedBasisExternalTaxPolicy do
  SHARED_BASIS_ITEM_LINE_TOTAL_LIMIT = 999_999_999

  def line_evidence(line_index, span_start, span_end)
    {
      source_provider: 'azure_item_layout',
      source_field_path: "pages[0].lines[#{line_index}]",
      page_index: 0,
      line_index: line_index,
      string_index_type: 'textElements',
      provider_span_start: span_start,
      provider_span_end: span_end
    }
  end

  def candidate
    {
      candidate_id: 'azure_item_layout_p0_name_l9_ref_l11_qty_l12_total_l13_reference_pricing',
      item_identity: 'azure_structured_item_i0_s98_e124',
      source_kind: 'azure_item_layout',
      page_index: 0,
      item_index: 0,
      destination_kind: 'azure_structured_item',
      structured_item_index: 0,
      name_line_index: 9,
      reference_line_index: 11,
      purchased_quantity_line_indexes: [ 12 ],
      printed_total_line_index: 13,
      owned_line_indexes: [ 6, 9, 10, 11, 12, 13 ],
      block_provider_span_start: 98,
      block_provider_span_end: 124,
      reference_line_provider_span_start: 110,
      reference_line_provider_span_end: 114,
      provider_model_id: 'prebuilt-receipt',
      provider_api_version: '2024-11-30',
      string_index_type: 'textElements',
      validation_contract_version: 'azure_item_layout_shared_basis_v1',
      validation_state: 'ambiguous',
      rejection_reasons: [ 'ambiguous_tax_inclusion' ],
      reference_price: {
        amount: '298',
        evidence: line_evidence(11, 110, 114)
      },
      reference_quantity: {
        amount: '100',
        unit_code: 'gram',
        unit_status: 'known',
        origin: 'explicit',
        evidence: line_evidence(6, 67, 71)
      },
      purchased_quantity: {
        amount: '199',
        unit_code: 'gram',
        unit_status: 'known',
        evidence: line_evidence(12, 115, 119)
      },
      reference_price_tax_inclusion: 'unknown',
      tax_inclusion_evidence: nil,
      printed_line_total: {
        amount: '593',
        evidence: line_evidence(13, 120, 124)
      },
      corroboration: {
        exact_amount: { numerator: '29651', denominator: '50' },
        projected_amount: 593,
        printed_line_total: '593',
        rounding_matches: [ 'floor', 'half_up' ]
      }
    }
  end

  def tax_detail_structural_metadata
    Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::Result.new(
      source_provider: 'azure_structured',
      provider_model_id: 'prebuilt-receipt',
      provider_api_version: '2024-11-30',
      string_index_type: 'textElements',
      tax_details: [
        {
          tax_detail_index: 0,
          parent: {
            source_provider: 'azure_structured',
            source_field_path: 'documents[0].fields.TaxDetails[0]',
            tax_detail_index: 0,
            provider_spans: [ { provider_span_start: 146, provider_span_end: 164 } ]
          },
          tax_inclusion_evidence: {
            kind: 'external_tax',
            tax_inclusion: 'net',
            source_provider: 'azure_structured',
            source_field_path: 'documents[0].fields.TaxDetails[0].Description',
            tax_detail_index: 0,
            page_index: 0,
            line_index: 19,
            string_index_type: 'textElements',
            provider_span_start: 152,
            provider_span_end: 154
          },
          rate: {
            source_provider: 'azure_structured',
            source_field_path: 'documents[0].fields.TaxDetails[0].Rate',
            tax_detail_index: 0,
            page_index: 0,
            line_index: 20,
            string_index_type: 'textElements',
            provider_span_start: 155,
            provider_span_end: 160,
            rate: '0.08'
          },
          net_amount: {
            source_provider: 'azure_structured',
            source_field_path: 'documents[0].fields.TaxDetails[0].NetAmount',
            tax_detail_index: 0,
            page_index: 0,
            line_index: 18,
            string_index_type: 'textElements',
            provider_span_start: 146,
            provider_span_end: 150,
            amount: 593
          },
          tax_amount: {
            source_provider: 'azure_structured',
            source_field_path: 'documents[0].fields.TaxDetails[0].Amount',
            tax_detail_index: 0,
            page_index: 0,
            line_index: 21,
            string_index_type: 'textElements',
            provider_span_start: 161,
            provider_span_end: 164,
            amount: 47
          }
        }
      ]
    )
  end

  def external_tax_evidence
    Ocr::ResponseParser::ReferencePricingSharedBasisExternalTaxEvidenceExtractor::Result.new(
      string_index_type: 'textElements',
      tax_detail_index: 0,
      subtotal: {
        source_provider: 'azure_structured',
        source_field_path: 'documents[0].fields.Subtotal',
        page_index: 0,
        line_index: 15,
        string_index_type: 'textElements',
        provider_span_start: 128,
        provider_span_end: 132,
        amount: 593
      },
      document_tax_total: {
        source_provider: 'azure_structured',
        source_field_path: 'documents[0].fields.TotalTax',
        page_index: 0,
        line_index: 21,
        string_index_type: 'textElements',
        provider_span_start: 161,
        provider_span_end: 164,
        amount: 47
      },
      summary_total: {
        source_provider: 'azure_structured',
        source_field_path: 'documents[0].fields.Total',
        page_index: 0,
        line_index: 23,
        string_index_type: 'textElements',
        provider_span_start: 173,
        provider_span_end: 177,
        amount: 640
      }
    )
  end

  def evaluate(candidate_value: candidate, evidence_value: external_tax_evidence, metadata: tax_detail_structural_metadata, **overrides)
    described_class.call(
      candidate: candidate_value,
      item_identities: [ candidate_value[:item_identity] ],
      block_candidate_ids: [ candidate_value[:candidate_id] ],
      destination_identities: [ candidate_value[:item_identity] ],
      external_tax_evidence: evidence_value,
      tax_detail_structural_metadata: metadata,
      adjustment_count: 0,
      discount_count: 0,
      item_line_total_limit: SHARED_BASIS_ITEM_LINE_TOTAL_LIMIT,
      **overrides
    )
  end

  it '共有見出しcandidateの唯一の不足がexact外税basisならnetへ昇格できる' do
    expect(evaluate).to have_attributes(
      eligible: true,
      reason: 'eligible',
      reference_price_tax_inclusion: 'net',
      evidence_kind: 'shared_basis_external_tax_summary',
      candidate_id: candidate[:candidate_id],
      item_identity: candidate[:item_identity]
    )
  end

  it 'candidate・destination・tax detailをreceipt全体でexactly oneに限定する' do
    aggregate_failures do
      expect(evaluate(item_identities: [])).not_to be_eligible
      expect(evaluate(item_identities: [ candidate[:item_identity], 'other' ])).not_to be_eligible
      expect(evaluate(block_candidate_ids: [])).not_to be_eligible
      expect(evaluate(destination_identities: [])).not_to be_eligible
      expect(evaluate(adjustment_count: 1)).not_to be_eligible
      expect(evaluate(discount_count: 1)).not_to be_eligible
    end
  end

  it 'shared-basis identity・unknown tax state・component ownershipの不一致を拒否する' do
    mutations = [
      candidate.merge(validation_contract_version: 'azure_item_layout_v1'),
      candidate.merge(reference_price_tax_inclusion: 'net'),
      candidate.merge(validation_state: 'valid'),
      candidate.merge(rejection_reasons: []),
      candidate.merge(destination_kind: 'azure_layout_item'),
      candidate.deep_dup.tap { |value| value[:reference_quantity][:evidence][:line_index] = 7 },
      candidate.deep_dup.tap { |value| value[:purchased_quantity][:unit_code] = 'milliliter' }
    ]

    mutations.each do |invalid_candidate|
      expect(evaluate(candidate_value: invalid_candidate)).not_to be_eligible
    end
  end

  it 'formula・printed total・subtotal・tax detail netを1円境界まで完全一致させる' do
    printed_mismatch = candidate.deep_dup
    printed_mismatch[:printed_line_total][:amount] = '594'
    projected_mismatch = candidate.deep_dup
    projected_mismatch[:corroboration][:projected_amount] = 594
    subtotal_mismatch = external_tax_evidence.to_h.deep_dup
    subtotal_mismatch[:subtotal][:amount] = 594
    tax_net_mismatch = tax_detail_structural_metadata.to_h.deep_dup
    tax_net_mismatch.dig(:tax_details, 0, :net_amount)[:amount] = 594
    tax_net_mismatch = Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::Result.new(**tax_net_mismatch)

    aggregate_failures do
      expect(evaluate(candidate_value: printed_mismatch)).not_to be_eligible
      expect(evaluate(candidate_value: projected_mismatch)).not_to be_eligible
      expect(evaluate(evidence_value: subtotal_mismatch)).not_to be_eligible
      expect(evaluate(metadata: tax_net_mismatch)).not_to be_eligible
    end
  end

  it '外税semantic・税額alias・subtotal + tax = totalの不一致を拒否する' do
    missing_semantic = tax_detail_structural_metadata.to_h.deep_dup
    missing_semantic.dig(:tax_details, 0)[:tax_inclusion_evidence] = nil
    missing_semantic = Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::Result.new(**missing_semantic)
    gross_semantic = tax_detail_structural_metadata.to_h.deep_dup
    gross_semantic.dig(:tax_details, 0, :tax_inclusion_evidence)[:tax_inclusion] = 'gross'
    gross_semantic = Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::Result.new(**gross_semantic)
    tax_mismatch = external_tax_evidence.to_h.deep_dup
    tax_mismatch[:document_tax_total][:amount] = 48
    total_mismatch = external_tax_evidence.to_h.deep_dup
    total_mismatch[:summary_total][:amount] = 641

    aggregate_failures do
      expect(evaluate(metadata: missing_semantic)).not_to be_eligible
      expect(evaluate(metadata: gross_semantic)).not_to be_eligible
      expect(evaluate(evidence_value: tax_mismatch)).not_to be_eligible
      expect(evaluate(evidence_value: total_mismatch)).not_to be_eligible
    end
  end

  it 'TaxDetailのrateとnet amountから既存丸め方式で再現できない税額を拒否する' do
    inconsistent_rate = tax_detail_structural_metadata.to_h.deep_dup
    inconsistent_rate.dig(:tax_details, 0, :rate)[:rate] = '0.09'
    inconsistent_rate = Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::Result.new(
      **inconsistent_rate
    )

    expect(evaluate(metadata: inconsistent_rate)).not_to be_eligible
  end

  it 'TaxDetail parentをitem blockから完全分離し接触境界だけを許可する' do
    metadata_with_span = lambda do |span|
      value = tax_detail_structural_metadata.to_h.deep_dup
      value.dig(:tax_details, 0, :parent, :provider_spans).unshift(
        provider_span_start: span.begin,
        provider_span_end: span.end
      )
      Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::Result.new(**value)
    end

    boundary = metadata_with_span.call(90...98)
    partial_overlap = metadata_with_span.call(90...100)
    inside_overlap = metadata_with_span.call(100...110)

    aggregate_failures do
      expect(evaluate(metadata: boundary)).to be_eligible
      expect(evaluate(metadata: partial_overlap)).not_to be_eligible
      expect(evaluate(metadata: inside_overlap)).not_to be_eligible
    end
  end
end
