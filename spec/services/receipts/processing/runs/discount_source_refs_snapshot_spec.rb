require 'rails_helper'

RSpec.describe Receipts::Processing::Runs::SnapshotBuilder do
  let(:lines) { [ '例示品 600円', '値引 -120円', '(1個 -60円)' ] }
  let(:references) do
    [
      { source_line_index: 1, source_span_start: 3, source_span_end: 8, amount: 120 },
      { source_line_index: 2, source_span_start: 4, source_span_end: 8, amount: 60 }
    ]
  end

  def build_discount_snapshot(refs = references)
    described_class.ocr_result_snapshot(
      success: true,
      lines: lines,
      candidates: {
        country_region: 'JPN',
        items: [ { raw_text: '例示品', line_total: 480, discount_amount: 120, discount_source_refs: refs } ]
      }
    )
  end

  it 'preserves only exact signed discount token references through snapshot and rehydration' do
    snapshot = build_discount_snapshot
    restored = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(snapshot)

    aggregate_failures do
      expect(snapshot.dig('candidates', 'items', 0, 'discount_source_refs')).to eq(references.map(&:stringify_keys))
      expect(restored.dig(:candidates, 'items', 0, 'discount_source_refs')).to eq(references.map(&:stringify_keys))
      expect(described_class.ocr_result_snapshot(restored)).to eq(snapshot)
      expect(snapshot.dig('candidates', 'items', 0, 'discount_amount')).to eq(120)
    end
  end

  {
    'unknown key' => lambda do |refs|
      refs.last[:raw_text] = 'private source'
      refs
    end,
    'non-integer amount' => lambda do |refs|
      refs.last[:amount] = '60'
      refs
    end,
    'different amount' => lambda do |refs|
      refs.last[:amount] = 61
      refs
    end,
    'negative amount' => lambda do |refs|
      refs.last[:amount] = -60
      refs
    end,
    'zero amount' => lambda do |refs|
      refs.last[:amount] = 0
      refs
    end,
    'negative index' => lambda do |refs|
      refs.last[:source_line_index] = -1
      refs
    end,
    'missing line' => lambda do |refs|
      refs.last[:source_line_index] = 3
      refs
    end,
    'partial token' => lambda do |refs|
      refs.last[:source_span_start] += 1
      refs
    end,
    'out-of-range end' => lambda do |refs|
      refs.last[:source_span_end] = 100_000_000
      refs
    end,
    'duplicate token' => ->(refs) { refs << refs.first.deep_dup },
    'oversized array' => ->(refs) { Array.new(17) { refs.first.deep_dup } },
    'invalid entry' => ->(refs) { refs << nil },
    'non-array payload' => ->(_refs) { { amount: 120 } }
  }.each do |description, mutation|
    it "rejects the complete discount reference array for #{description}" do
      snapshot = build_discount_snapshot(mutation.call(references.deep_dup))

      aggregate_failures do
        expect(snapshot.dig('candidates', 'items', 0)).not_to have_key('discount_source_refs')
        expect(snapshot.to_json).not_to include('private source')
        expect(snapshot.dig('candidates', 'items', 0, 'discount_amount')).to eq(120)
      end
    end
  end

  it 'does not preserve unsigned tokens as discount ownership evidence' do
    references.replace([ { source_line_index: 0, source_span_start: 3, source_span_end: 8, amount: 600 } ])

    expect(build_discount_snapshot.dig('candidates', 'items', 0)).not_to have_key('discount_source_refs')
  end

  it 'rejects references into a line that was truncated for storage' do
    lines[1] += 'あ' * described_class::STRING_MAX_BYTES

    expect(build_discount_snapshot.dig('candidates', 'items', 0)).not_to have_key('discount_source_refs')
  end

  it 'does not shift a reference to an identical line when an earlier line is removed' do
    lines.replace([ nil, '値引 -120円', '値引 -120円' ])
    references.replace([ { source_line_index: 1, source_span_start: 3, source_span_end: 8, amount: 120 } ])

    expect(build_discount_snapshot.dig('candidates', 'items', 0)).not_to have_key('discount_source_refs')
  end

  it 'preserves the maximum sixteen distinct references without truncation' do
    lines.replace(Array.new(16, '値引 -120円'))
    references.replace(Array.new(16) do |index|
      { source_line_index: index, source_span_start: 3, source_span_end: 8, amount: 120 }
    end)

    expect(build_discount_snapshot.dig('candidates', 'items', 0, 'discount_source_refs').size).to eq(16)
  end

  it 'rejects a signed percentage token instead of treating it as discount money' do
    lines[1] += '%'

    expect(build_discount_snapshot.dig('candidates', 'items', 0)).not_to have_key('discount_source_refs')
  end
end
