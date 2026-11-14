require 'rails_helper'

RSpec.describe Receipts::Processing::Runs::SnapshotBuilder do
  let(:lines) { [ '001 例示市商品券 900' ] }
  let(:references) { [ { line_index: 0, character_offset: 4, character_length: 6 } ] }
  let(:item) { { raw_text: '例示市商品券', line_total: 900, description_source_refs: references } }

  def description_snapshot(items = [ item ])
    described_class.ocr_result_snapshot(success: true, lines: lines, candidates: { country_region: 'JPN', items: items })
  end

  it '完全な商品名と参照行を維持できる場合だけ構造情報を往復する' do
    snapshot = description_snapshot
    restored = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(snapshot)

    aggregate_failures do
      expect(snapshot.dig('candidates', 'items', 0, 'description_source_refs')).to eq(references.map(&:stringify_keys))
      expect(restored.dig(:candidates, 'items', 0, 'description_source_refs')).to eq(references.map(&:stringify_keys))
      expect(described_class.ocr_result_snapshot(restored)).to eq(snapshot)
    end
  end

  {
    'unknown field' => ->(refs) { refs.first[:content] = 'private source' },
    'negative index' => ->(refs) { refs.first[:line_index] = -1 },
    'missing line' => ->(refs) { refs.first[:line_index] = 1 },
    'string offset' => ->(refs) { refs.first[:character_offset] = '4' },
    'negative offset' => ->(refs) { refs.first[:character_offset] = -1 },
    'zero length' => ->(refs) { refs.first[:character_length] = 0 },
    'out-of-range length' => ->(refs) { refs.first[:character_length] = 100_000_000 },
    'partial description' => ->(refs) { refs.first[:character_length] -= 1 },
    'duplicate reference' => ->(refs) { refs << refs.first.deep_dup },
    'overlapping reference' => ->(refs) { refs << { line_index: 0, character_offset: 5, character_length: 3 } },
    'too many references' => ->(refs) { refs.replace(Array.new(17, refs.first)) },
    'malformed entry' => ->(refs) { refs << nil }
  }.each do |name, mutation|
    it "#{name}ではproof全体だけを落とす" do
      mutation.call(references)
      snapshot = description_snapshot

      aggregate_failures do
        expect(snapshot.dig('candidates', 'items', 0)).not_to have_key('description_source_refs')
        expect(snapshot.dig('candidates', 'items', 0)).to include('raw_text' => '例示市商品券', 'line_total' => 900)
        expect(snapshot.to_json).not_to include('private source')
      end
    end
  end

  it '既存snapshotにproofがなければ新しく推測しない' do
    item.delete(:description_source_refs)

    expect(description_snapshot.dig('candidates', 'items', 0)).not_to have_key('description_source_refs')
  end

  it '参照行の切詰め後は有効なprefixであってもproofを保持しない' do
    lines.first << 'あ' * described_class::STRING_MAX_BYTES

    expect(description_snapshot.dig('candidates', 'items', 0)).not_to have_key('description_source_refs')
  end

  it '商品名の切詰め後はproofを保持しない' do
    item[:raw_text] << 'あ' * described_class::STRING_MAX_BYTES

    expect(description_snapshot.dig('candidates', 'items', 0)).not_to have_key('description_source_refs')
  end

  it '商品名に改行以外の制御文字があればproofを保持しない' do
    item[:raw_text] << "\0"

    expect(description_snapshot.dig('candidates', 'items', 0)).not_to have_key('description_source_refs')
  end

  it '空行削除後に同じ文字列の別行へ参照をずらさない' do
    lines.unshift(nil)
    references.first[:line_index] = 1

    expect(description_snapshot.dig('candidates', 'items', 0)).not_to have_key('description_source_refs')
  end

  it '別商品同士が同じ範囲を主張した場合は双方のproofを落とす' do
    snapshot = description_snapshot([ item, item.deep_dup ])

    expect(snapshot.dig('candidates', 'items')).to all(satisfy { |entry| !entry.key?('description_source_refs') })
  end

  it '正規化された複数行の商品名と最大16参照を切り詰めず往復する' do
    lines.replace(Array.new(16, '例示品'))
    item[:raw_text] = lines.join("\n")
    references.replace(lines.each_index.map { |index| { line_index: index, character_offset: 0, character_length: 3 } })

    expect(description_snapshot.dig('candidates', 'items', 0, 'description_source_refs')).to eq(references.map(&:stringify_keys))
  end

  it '商品名proofの上限100明細を超えたとき商品を削除せずproofを落とす' do
    snapshot = description_snapshot(Array.new(101) { item.deep_dup })

    aggregate_failures do
      expect(snapshot.dig('candidates', 'items').size).to eq(101)
      expect(snapshot.dig('candidates', 'items')).to all(satisfy { |entry| !entry.key?('description_source_refs') })
    end
  end

  it '前後の別商品参照が包含関係で重なる場合も全所有権を拒否する' do
    lines.replace([ '例示市商品券' ])
    items = [ [ '例示市商品券', 0, 6 ], [ '例示', 0, 2 ], [ '市商品', 2, 3 ] ].map do |name, offset, length|
      { raw_text: name, line_total: 900, description_source_refs: [ { line_index: 0, character_offset: offset, character_length: length } ] }
    end

    expect(description_snapshot(items).dig('candidates', 'items')).to all(satisfy { |entry| !entry.key?('description_source_refs') })
  end
end
