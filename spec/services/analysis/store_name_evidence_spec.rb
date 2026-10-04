require 'rails_helper'

RSpec.describe Analysis::StoreNameEvidence do
  let(:candidate) do
    {
      candidate_id: 'merchant_name', text: 'Sample Store', source: 'merchant_name',
      source_path: 'documents[0].fields.MerchantName', confidence: 0.87, span_state: 'missing'
    }
  end
  let(:evidence) do
    { schema_version: 'store_name_evidence_v1', candidates: [ candidate ], truncated: false, invalid: false }
  end

  it 'round-trips bounded atomic evidence without mutating the input' do
    original = evidence.deep_dup
    result = described_class.call(JSON.parse(evidence.to_json))

    aggregate_failures do
      expect(result).to eq(evidence)
      expect(result).to be_frozen
      expect(result[:candidates].first[:text]).to be_frozen
      expect(evidence).to eq(original)
    end
  end

  it 'distinguishes missing legacy evidence from malformed supplied evidence' do
    aggregate_failures do
      expect(described_class.call(nil)).to be_nil
      expect(described_class.call({})).to include(invalid: true, candidates: [])
      expect(described_class.call(evidence.merge(schema_version: 'unknown'))).to include(invalid: true)
    end
  end

  it 'marks a bounded candidate subset truncated and retains that state on retry' do
    second = candidate.merge(candidate_id: 'line_1', source: 'line', source_path: 'lines[1]', line_index: 1)
    second.delete(:confidence)
    result = described_class.call(evidence.merge(candidates: [ candidate, second ]), max_candidates: 1)

    aggregate_failures do
      expect(result).to include(candidates: [ candidate ], truncated: true, invalid: false)
      expect(described_class.call(result)).to eq(result)
    end
  end

  it 'rejects duplicate or contradictory source identities without preserving arbitrary fields' do
    aggregate_failures do
      expect(described_class.call(evidence.merge(candidates: [ candidate, candidate ]))).to include(invalid: true)
      expect(described_class.call(evidence.merge(prompt: 'not retained')).to_json).not_to include('not retained')
      candidate[:source_path] = 'pages[0].lines[1]'
      expect(described_class.call(evidence)).to include(invalid: true)
    end
  end

  it 'rejects oversized text instead of creating a shortened store identity' do
    candidate[:text] = 'a' * 501

    expect(described_class.call(evidence)).to include(invalid: true, candidates: [])
  end

  it 'rejects controls, invalid confidence and unknown span types' do
    aggregate_failures do
      expect(described_class.call(evidence.deep_merge(candidates: [ candidate.merge(text: "Store\u0000") ]))).to include(invalid: true)
      expect(described_class.call(evidence.deep_merge(candidates: [ candidate.merge(confidence: Float::NAN) ]))).to include(invalid: true)
      exact = candidate.merge(span_state: 'exact', string_index_type: 'unknown', span: { offset: 0, length: 12 })
      expect(described_class.call(evidence.merge(candidates: [ exact ]))).to include(invalid: true)
    end
  end

  it 'preserves an invalid association as invalid rather than weakening it to missing' do
    candidate[:span_state] = 'invalid'

    expect(described_class.call(evidence).dig(:candidates, 0, :span_state)).to eq('invalid')
  end
end
