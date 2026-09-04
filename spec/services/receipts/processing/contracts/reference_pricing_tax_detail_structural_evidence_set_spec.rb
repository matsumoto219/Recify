require 'rails_helper'

RSpec.describe Receipts::Processing::Contracts::ReferencePricingTaxDetailStructuralEvidenceSet do
  def metadata
    {
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
            provider_spans: [
              { provider_span_start: 100, provider_span_end: 120 },
              { provider_span_start: 130, provider_span_end: 150 }
            ]
          },
          tax_inclusion_evidence: {
            kind: 'external_tax',
            tax_inclusion: 'net',
            source_provider: 'azure_structured',
            source_field_path: 'documents[0].fields.TaxDetails[0].Description',
            tax_detail_index: 0,
            page_index: 0,
            line_index: 10,
            string_index_type: 'textElements',
            provider_span_start: 100,
            provider_span_end: 102
          },
          rate: {
            source_provider: 'azure_structured',
            source_field_path: 'documents[0].fields.TaxDetails[0].Rate',
            tax_detail_index: 0,
            page_index: 0,
            line_index: 11,
            string_index_type: 'textElements',
            provider_span_start: 110,
            provider_span_end: 112,
            rate: '0.08'
          },
          net_amount: {
            source_provider: 'azure_structured',
            source_field_path: 'documents[0].fields.TaxDetails[0].NetAmount',
            tax_detail_index: 0,
            page_index: 0,
            line_index: 12,
            string_index_type: 'textElements',
            provider_span_start: 130,
            provider_span_end: 136,
            amount: 593
          },
          tax_amount: {
            source_provider: 'azure_structured',
            source_field_path: 'documents[0].fields.TaxDetails[0].Amount',
            tax_detail_index: 0,
            page_index: 0,
            line_index: 13,
            string_index_type: 'textElements',
            provider_span_start: 140,
            provider_span_end: 145,
            amount: 47
          }
        }
      ]
    }
  end

  def ocr_snapshot
    {
      schema_version: 'receipt_analysis_run_ocr_result_v1',
      candidates: {
        tax_details: [
          { description: '外税', rate: 0.08, net_amount: 593.0, amount: 47.0 }
        ]
      },
      candidate_counts: {
        tax_details: { actual_count: 1, snapshot_count: 1 }
      },
      truncated: { tax_details: false }
    }
  end

  it 'exact metadataをversioned checksum付きcontractへ変換してround-tripする' do
    source = Marshal.load(Marshal.dump(metadata))
    proposal = described_class.build(metadata:, ocr_snapshot:)
    restored = described_class.from_snapshot(proposal, ocr_snapshot:)

    aggregate_failures do
      expect(proposal).to include(
        'schema_version' => 'reference_pricing_tax_detail_structural_evidence_set_v1',
        'creation_stage' => 'ocr_validation',
        'source_provider' => 'azure_structured',
        'provider_model_id' => 'prebuilt-receipt',
        'provider_api_version' => '2024-11-30',
        'string_index_type' => 'textElements',
        'integrity_checksum' => match(/\A[0-9a-f]{64}\z/)
      )
      expect(proposal.fetch('tax_details').sole.dig('rate', 'rate')).to eq('0.08')
      expect(proposal.fetch('tax_details').sole.fetch('tax_inclusion_evidence')).to include(
        'kind' => 'external_tax',
        'tax_inclusion' => 'net'
      )
      expect(restored).to eq(proposal)
      expect(metadata).to eq(source)
      expect(JSON.generate(proposal).bytesize).to be <= described_class::MAX_SERIALIZED_BYTES
      expect(proposal.to_json).not_to match(/外税|content|polygon|raw_response/)
    end
  end

  it 'unknown version・unknown field・checksum mismatch・partial childをset全体で拒否する' do
    proposal = described_class.build(metadata:, ocr_snapshot:)
    mutations = [
      proposal.merge('schema_version' => 'reference_pricing_tax_detail_structural_evidence_set_v2'),
      proposal.merge('unknown' => true),
      proposal.merge('integrity_checksum' => '0' * 64),
      proposal.deep_merge('tax_details' => [ { 'rate' => { 'rate' => '0.1' } } ]),
      proposal.deep_merge('tax_details' => [ { 'rate' => { 'content' => '8%' } } ]),
      proposal.deep_merge('tax_details' => [ { 'parent' => { 'polygon' => [ 0, 0, 1, 1 ] } } ]),
      proposal.deep_merge('tax_details' => [ { 'tax_inclusion_evidence' => { 'tax_inclusion' => 'gross' } } ]),
      proposal.deep_merge('tax_details' => [ { 'net_amount' => { 'amount' => 594 } } ]),
      proposal.deep_merge('tax_details' => [ { 'parent' => { 'provider_spans' => [] } } ])
    ]

    mutations.each do |mutation|
      expect(described_class.from_snapshot(mutation, ocr_snapshot:)).to be_nil
    end
  end

  it 'normal TaxDetails・count・truncationとの不一致を拒否する' do
    proposal = described_class.build(metadata:, ocr_snapshot:)
    contexts = [
      ocr_snapshot.deep_merge('candidates' => { 'tax_details' => [ { 'rate' => 0.1 } ] }),
      ocr_snapshot.deep_merge('candidate_counts' => { 'tax_details' => { 'actual_count' => 2 } }),
      ocr_snapshot.deep_merge('candidate_counts' => { 'tax_details' => { 'snapshot_count' => 0 } }),
      ocr_snapshot.deep_merge('truncated' => { 'tax_details' => true }),
      ocr_snapshot.merge('schema_version' => 'receipt_analysis_run_ocr_result_v2')
    ]

    contexts.each do |context|
      expect(described_class.from_snapshot(proposal, ocr_snapshot: context)).to be_nil
    end
  end

  it 'childがparentの個別span外・重複・path/index不一致なら拒否する' do
    cases = [
      metadata.deep_merge(
        tax_details: [ { rate: { provider_span_start: 121, provider_span_end: 123 } } ]
      ),
      metadata.deep_merge(
        tax_details: [ { tax_amount: { provider_span_start: 132, provider_span_end: 134 } } ]
      ),
      metadata.deep_merge(
        tax_details: [ { rate: { source_field_path: 'documents[0].fields.TaxDetails[1].Rate' } } ]
      ),
      metadata.deep_merge(tax_details: [ { tax_detail_index: 1 } ]),
      metadata.deep_merge(
        tax_details: [ { parent: { provider_spans: metadata.dig(:tax_details, 0, :parent, :provider_spans).reverse } } ]
      ),
      metadata.deep_merge(tax_details: [ { rate: { page_index: -1 } } ]),
      metadata.merge(string_index_type: 'unicodeCodePoint')
    ]

    cases.each do |value|
      expect(described_class.build(metadata: value, ocr_snapshot:)).to be_nil
    end
  end

  it 'oversized・invalid encoding・control characterをboundedに拒否する' do
    oversized = metadata.deep_merge(
      tax_details: Array.new(described_class::MAX_TAX_DETAILS + 1) { metadata[:tax_details].sole }
    )
    invalid = metadata.deep_dup
    invalid[:source_provider] = "\xFF".dup.force_encoding(Encoding::UTF_8)
    control = metadata.merge(source_provider: "azure\u0000structured")

    [ oversized, invalid, control ].each do |value|
      expect { described_class.build(metadata: value, ocr_snapshot:) }.not_to raise_error
      expect(described_class.build(metadata: value, ocr_snapshot:)).to be_nil
    end
  end
end
