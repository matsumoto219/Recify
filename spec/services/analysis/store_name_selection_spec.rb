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

    context '候補集合のversionを保持する場合' do
      let(:versioned_options) { options.merge(schema_version: 'store_name_options_v1').freeze }
      let(:selection) do
        { decision: 'select', option_id: 'store_option_0123456789abcdef0123456789abcdef' }.freeze
      end

      it '実際に提示した候補集合のversionをbindして保存往復でも維持する' do
        result = described_class.call(selection, options: versioned_options)

        expect(result).to eq(
          decision: 'select', option_id: 'store_option_0123456789abcdef0123456789abcdef',
          options_checksum: 'a' * 64, options_schema_version: 'store_name_options_v1'
        )
        expect(described_class.call(JSON.parse(result.to_json))).to eq(result)
        expect(described_class.call(result, options: versioned_options.deep_stringify_keys)).to eq(result)
        expect(selection.keys).to eq(%i[decision option_id])
      end

      it '同じversionの保存済み選択だけを再bindする' do
        stored = selection.merge(options_schema_version: 'store_name_options_v1', options_checksum: 'a' * 64)

        expect(described_class.call(stored, options: versioned_options)).to eq(stored)
        expect(described_class.call(stored, options: options)).to eq(decision: 'invalid', options_checksum: 'a' * 64)
      end

      it '未知または不正な保存versionを現在の選択へ読み替えない' do
        [ 'store_name_options_v2', 'x' * 65, nil, false, 1, [], "\xFF".b ].each do |version|
          stored = selection.merge(options_schema_version: version)

          expect(described_class.call(stored)).to eq(decision: 'invalid')
          expect(described_class.call(stored, options: versioned_options)).to eq(
            decision: 'invalid', options_checksum: 'a' * 64, options_schema_version: 'store_name_options_v1'
          )
        end
      end

      it '未知または不正な候補集合versionでは選択を採用しない' do
        [ 'store_name_options_v2', nil, false, [], "\xFF".b ].each do |version|
          expect(described_class.call(selection, options: options.merge(schema_version: version))).to eq(
            decision: 'invalid', options_checksum: 'a' * 64
          )
        end
      end

      it '選択拒否後も検証した候補集合のversionとchecksumを残す' do
        [
          nil,
          selection.merge(option_id: 'store_option_1123456789abcdef0123456789abcdef'),
          selection.merge(options_checksum: 'b' * 64)
        ].each do |stored|
          expect(described_class.call(stored, options: versioned_options)).to eq(
            decision: 'invalid', options_checksum: 'a' * 64, options_schema_version: 'store_name_options_v1'
          )
        end
      end
    end
  end
end
