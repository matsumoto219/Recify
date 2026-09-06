require 'rails_helper'

RSpec.describe Analysis::ReceiptItemNormalizer do
  describe '.normalize_ai_item' do
    [ 0, 1, '0', '1' ].each do |index|
      it "整数index #{index.inspect}を保持する" do
        expect(described_class.normalize_ai_item(index: index, suggested_name: 'ノート A5')).to include(index: index.to_i)
      end
    end

    [ 1.5, '1.5', Float::NAN, Float::INFINITY, -1, true, nil ].each do |index|
      it "不正index #{index.inspect}を整数へ丸めない" do
        item = described_class.normalize_ai_item(index: index, suggested_name: 'ノート A5')

        aggregate_failures do
          expect(item).not_to have_key(:index)
          expect(item[:suggested_name]).to eq('ノート A5')
        end
      end
    end

    it 'position_index互換入力も小数を整数へ丸めない' do
      expect(described_class.normalize_ai_item(position_index: 1.5, suggested_name: 'ノート A5')).not_to have_key(:index)
    end

    it '明示された不正indexをposition_indexで補わない' do
      expect(described_class.normalize_ai_item(index: nil, position_index: 0, suggested_name: 'ノート A5')).not_to have_key(:index)
    end

    it '巨大文字列・非ASCII互換encodingのindexを整数へ変換しない' do
      [ '0' * 128, '1'.encode(Encoding::UTF_16LE) ].each do |index|
        expect(described_class.normalize_ai_item(index: index, suggested_name: 'ノート A5')).not_to have_key(:index)
      end
    end
  end
end
