require 'rails_helper'

RSpec.describe Analysis::StoreNameSelection do
  let(:options) do
    {
      checksum: 'a' * 64,
      options: [ { option_id: 'store_option_0123456789abcdef0123456789abcdef' } ]
    }
  end

  describe '.call' do
    it '旧結果の選択欠損と、新しい候補集合に対する未選択を区別する' do
      expect(described_class.call(nil)).to be_nil
      expect(described_class.call(nil, options: options)).to eq(
        decision: 'invalid', options_checksum: 'a' * 64
      )
    end

    it '実在するoptionだけを現在の候補集合へbindする' do
      result = described_class.call(
        { decision: 'select', option_id: 'store_option_0123456789abcdef0123456789abcdef' }, options: options
      )

      expect(result).to eq(
        decision: 'select', option_id: 'store_option_0123456789abcdef0123456789abcdef', options_checksum: 'a' * 64
      )
      expect(described_class.call(result, options: options)).to eq(result)
    end

    it 'rejectとambiguousにoptionを持たせない' do
      %w[reject ambiguous].each do |decision|
        expect(described_class.call({ decision: decision, option_id: nil }, options: options)).to eq(
          decision: decision, options_checksum: 'a' * 64
        )
        expect(described_class.call({ decision: decision, option_id: 'store_option_0123456789abcdef0123456789abcdef' })).to eq(decision: 'invalid')
      end
    end

    it '未知IDと古い候補集合への選択を採用しない' do
      [
        { decision: 'select', option_id: 'store_option_1123456789abcdef0123456789abcdef' },
        { decision: 'select', option_id: 'store_option_0123456789abcdef0123456789abcdef', options_checksum: 'b' * 64 }
      ].each do |selection|
        expect(described_class.call(selection, options: options)).to eq(
          decision: 'invalid', options_checksum: 'a' * 64
        )
      end
    end

    it '不正な型・未知キー・長大値をraw値なしで拒否する' do
      [
        [], 'private text', { decision: 'unknown' },
        { decision: 'select', option_id: 'x' * 101 },
        { decision: 'select', option_id: "store_option_0\n" },
        { decision: 'select', option_id: 'store_option_0', raw_text: 'private text' },
        { decision: 'select', option_id: 'store_option_0', options_checksum: 'secret' }
      ].each do |selection|
        expect(described_class.call(selection)).to eq(decision: 'invalid')
      end
    end

    it '入力を変更せず、文字列keyの保存結果も同じ意味へ戻す' do
      selection = { 'decision' => 'select', 'option_id' => 'store_option_0123456789abcdef0123456789abcdef' }.freeze
      result = described_class.call(selection, options: options)

      expect(selection.keys).to eq(%w[decision option_id])
      expect(described_class.call(JSON.parse(result.to_json))).to eq(result)
    end
  end
end
