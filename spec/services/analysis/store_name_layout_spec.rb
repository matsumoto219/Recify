require 'rails_helper'

RSpec.describe Analysis::StoreNameLayout do
  let(:candidate) do
    {
      candidate_id: 'page_0_line_0', text: 'Sample Store', source: 'line',
      source_path: 'pages[0].lines[0]', line_index: 0, page_index: 0, provider_line_index: 0,
      span_state: 'exact', span: { offset: 0, length: 12 }, string_index_type: 'textElements'
    }
  end
  let(:evidence) do
    { schema_version: 'store_name_evidence_v1', candidates: [ candidate ], truncated: false, invalid: false }
  end
  let(:entry) do
    {
      candidate_id: 'page_0_line_0', page_index: 0, provider_line_index: 0,
      line_span: { offset: 0, length: 12 }, bounds: { left: 1_000, top: 500, width: 4_000, height: 300 }
    }
  end
  let(:layout) { { scope: 'provider_line', coordinate_scale: 10_000, entries: [ entry ] } }

  def normalize(value = layout)
    described_class.call(value, evidence: evidence)
  end

  it 'keeps bounded line geometry separate from immutable candidate evidence' do
    original_layout = layout.deep_dup
    original_evidence = evidence.deep_dup
    result = normalize(JSON.parse(layout.to_json))

    aggregate_failures do
      expect(result).to eq(layout)
      expect(result).to be_frozen
      expect(result[:entries].first[:bounds]).to be_frozen
      expect(result[:entries].first[:candidate_id]).to be_frozen
      expect(layout).to eq(original_layout)
      expect(evidence).to eq(original_evidence)
      expect(result.to_json).not_to include('Sample Store', 'source_path', 'polygon')
    end
  end

  it 'retains the whole provider line for a candidate covering only part of it' do
    entry[:line_span] = { offset: 0, length: 20 }

    expect(normalize).to eq(layout)
    expect(candidate[:span]).to eq(offset: 0, length: 12)
  end

  it 'accepts a merchant field only when its exact source links to the same line' do
    candidate.merge!(candidate_id: 'merchant_name', source: 'merchant_name', source_path: 'documents[0].fields.MerchantName')
    entry[:candidate_id] = 'merchant_name'

    expect(normalize).to eq(layout)
  end

  it 'keeps existing candidates when layout is missing or empty' do
    original = evidence.deep_dup

    aggregate_failures do
      expect(normalize(nil)).to be_nil
      expect(normalize(layout.merge(entries: []))).to be_nil
      expect(normalize({})).to be_nil
      expect(evidence).to eq(original)
    end
  end

  it 'rejects unknown fields at every level instead of retaining arbitrary metadata' do
    aggregate_failures do
      expect(normalize(layout.merge(raw_response: 'not retained'))).to be_nil
      expect(normalize(layout.deep_merge(entries: [ entry.merge(text: 'not retained') ]))).to be_nil
      expect(normalize(layout.deep_merge(entries: [ entry.deep_merge(line_span: { content: 'not retained' }) ]))).to be_nil
      expect(normalize(layout.deep_merge(entries: [ entry.deep_merge(bounds: { polygon: [] }) ]))).to be_nil
    end
  end

  it 'rejects duplicate identities and duplicate string/symbol keys' do
    aggregate_failures do
      expect(normalize(layout.merge(entries: [ entry, entry.deep_dup ]))).to be_nil
      expect(normalize(layout.merge('scope' => 'provider_line'))).to be_nil
      expect(normalize(layout.merge(entries: [ entry.merge('candidate_id' => entry[:candidate_id]) ]))).to be_nil
    end
  end

  it 'omits an invalid entry while preserving a separately linked valid entry' do
    second_candidate = candidate.merge(
      candidate_id: 'page_0_line_1', source_path: 'pages[0].lines[1]', line_index: 1,
      provider_line_index: 1, span: { offset: 13, length: 12 }
    )
    evidence[:candidates] << second_candidate
    second_entry = entry.deep_dup.merge(candidate_id: second_candidate[:candidate_id], provider_line_index: 1, line_span: second_candidate[:span])
    layout[:entries] << second_entry
    entry[:bounds][:width] = -1

    expect(normalize).to eq(layout.merge(entries: [ second_entry ]))
    expect(evidence[:candidates].size).to eq(2)
  end

  it 'does not repair missing, invalid or unlinked source evidence' do
    aggregate_failures do
      expect(described_class.call(layout, evidence: nil)).to be_nil
      expect(described_class.call(layout, evidence: evidence.merge(invalid: true))).to be_nil
      expect(normalize(layout.merge(entries: [ entry.merge(candidate_id: 'page_0_line_1') ]))).to be_nil
      expect(normalize(layout.merge(entries: [ entry.merge(page_index: 1) ]))).to be_nil
      expect(normalize(layout.merge(entries: [ entry.merge(provider_line_index: 1) ]))).to be_nil
    end
    candidate[:span_state] = 'missing'
    candidate.delete(:span)
    candidate.delete(:string_index_type)

    expect(normalize).to be_nil
  end

  it 'can describe retained candidates without widening truncated evidence' do
    evidence[:truncated] = true

    expect(normalize).to eq(layout)
    expect(evidence[:truncated]).to be(true)
  end

  {
    'negative offset' => { offset: -1, length: 13 },
    'zero length' => { offset: 0, length: 0 },
    'partial overlap' => { offset: 1, length: 12 },
    'too short' => { offset: 0, length: 11 },
    'oversized endpoint' => { offset: 0, length: 10_000_001 },
    'noninteger index' => { offset: 0.0, length: 12 }
  }.each do |condition, span|
    it "omits a line span with #{condition}" do
      entry[:line_span] = span

      expect(normalize).to be_nil
    end
  end

  {
    'negative coordinate' => { left: -1 },
    'zero width' => { width: 0 },
    'zero height' => { height: 0 },
    'outside page' => { width: 10_000 },
    'floating point' => { top: 1.0 },
    'nonfinite value' => { top: Float::NAN }
  }.each do |condition, changes|
    it "omits bounds with #{condition}" do
      entry[:bounds].merge!(changes)

      expect(normalize).to be_nil
    end
  end

  it 'rejects a different coordinate system or scope' do
    aggregate_failures do
      expect(normalize(layout.merge(coordinate_scale: 100))).to be_nil
      expect(normalize(layout.merge(scope: 'candidate_text'))).to be_nil
    end
  end

  it 'rejects over-bound entries and serialized output without truncation' do
    aggregate_failures do
      expect(normalize(layout.merge(entries: Array.new(101, entry)))).to be_nil
      stub_const('Analysis::StoreNameLayout::MAX_BYTES', layout.to_json.bytesize - 1)
      expect(normalize).to be_nil
    end
  end

  it 'drops oversized or invalid identity strings before retaining metadata' do
    aggregate_failures do
      expect(normalize(layout.merge(entries: [ entry.merge(candidate_id: 'x' * 100_000) ]))).to be_nil
      expect(normalize(layout.merge(entries: [ entry.merge(candidate_id: "page_0_line_0\0") ]))).to be_nil
      expect(normalize(layout.merge(entries: [ entry.merge(candidate_id: "\xFF".b) ]))).to be_nil
    end
  end
end
