require 'rails_helper'

RSpec.describe ReceiptCalculationSettings, type: :model do
  let(:payload) do
    {
      'schema_version' => 1,
      'tax_rounding_mode' => { 'value' => 'floor', 'origin' => 'form_default' },
      'discount_rounding_mode' => { 'value' => 'round', 'origin' => 'manual' },
      'tax_rounding_scope' => { 'value' => 'per_tax_rate_group', 'origin' => 'application_default' },
      'purchase_adjustment_tax_inclusion' => { 'value' => 'gross', 'origin' => 'analysis' }
    }
  end

  describe '.parse' do
    it '保存された条件と由来だけを持つimmutableな値を返す' do
      settings = described_class.parse(payload)

      aggregate_failures do
        expect(settings).to be_frozen
        expect(settings.to_h).to eq(payload)
        expect(settings.value_for('tax_rounding_mode')).to eq('floor')
        expect(settings.origin_for('tax_rounding_mode')).to eq('form_default')
      end
    end

    it '記録済みの条件が1つでもあれば欠損を補完せず保持する' do
      partial = payload.slice('schema_version', 'tax_rounding_scope')
      settings = described_class.parse(partial)

      aggregate_failures do
        expect(settings.to_h).to eq(partial)
        expect(settings.value_for('tax_rounding_mode')).to be_nil
        expect(settings.origin_for('tax_rounding_mode')).to be_nil
        expect(settings.value_for('unknown')).to be_nil
        expect(settings.value_for('schema_version')).to be_nil
        expect(settings.origin_for('schema_version')).to be_nil
      end
    end

    {
      'tax_rounding_mode' => %w[floor round ceil],
      'discount_rounding_mode' => %w[floor round ceil],
      'tax_rounding_scope' => %w[per_item per_tax_rate_group per_receipt],
      'purchase_adjustment_tax_inclusion' => %w[gross net]
    }.each do |key, values|
      values.each do |value|
        it "#{key}の#{value}を元のcodeのまま保持する" do
          payload[key]['value'] = value

          expect(described_class.parse(payload).value_for(key)).to eq(value)
        end
      end
    end

    %w[manual form_default application_default analysis legacy_record].each do |origin|
      it "許可された由来#{origin}を推定せず保持する" do
        payload['tax_rounding_mode']['origin'] = origin

        expect(described_class.parse(payload).origin_for('tax_rounding_mode')).to eq(origin)
      end
    end

    it '入力も入力のネスト値も変更・freezeしない' do
      original = payload.deep_dup

      described_class.parse(payload)

      aggregate_failures do
        expect(payload).to eq(original)
        expect(payload).not_to be_frozen
        expect(payload['tax_rounding_mode']).not_to be_frozen
        expect(payload['tax_rounding_mode']['value']).not_to be_frozen
      end
    end

    it '解析後の入力の変更が検証済みの値に影響しない' do
      settings = described_class.parse(payload)
      payload['tax_rounding_mode']['value'].replace('ceil')
      payload['tax_rounding_mode']['origin'].replace('manual')
      payload.clear

      aggregate_failures do
        expect(settings.value_for('tax_rounding_mode')).to eq('floor')
        expect(settings.origin_for('tax_rounding_mode')).to eq('form_default')
      end
    end

    it 'Hash以外や未記録を有効な既定値へ変換しない' do
      inputs = [ nil, false, [], '', '{}', {}, { 'schema_version' => 1 } ]

      inputs.each do |input|
        expect(described_class.parse(input)).to be_nil
      end
    end

    it 'versionの型違い・欠損・未知versionを拒否する' do
      [ nil, '1', 1.0, true, 0, 2, [], {} ].each do |version|
        expect(described_class.parse(payload.merge('schema_version' => version))).to be_nil
      end
      expect(described_class.parse(payload.except('schema_version'))).to be_nil
    end

    it 'rootの未知keyやsymbol keyをstring化せず拒否する' do
      inputs = [
        payload.merge('unknown' => 'private'),
        payload.merge(schema_version: 1),
        payload.transform_keys(&:to_sym)
      ]

      inputs.each do |input|
        expect(described_class.parse(input)).to be_nil
      end
    end

    it 'entryの欠損・未知key・symbol key・型違いを拒否する' do
      entries = [
        nil, [], 'floor', {},
        { 'value' => 'floor' },
        { 'origin' => 'manual' },
        { 'value' => 'floor', 'origin' => 'manual', 'raw' => 'private' },
        { 'value' => 'floor', 'origin' => 'manual', value: 'ceil' },
        { value: 'floor', origin: 'manual' }
      ]

      entries.each do |entry|
        expect(described_class.parse(payload.merge('tax_rounding_mode' => entry))).to be_nil
      end
    end

    it 'valueとoriginをstrip・case変換・to_sで補正しない' do
      invalid_values = [ nil, false, 0, :floor, 'FLOOR', ' floor', 'floor ', '', [], {} ]
      invalid_origins = [ nil, false, 0, :manual, 'MANUAL', ' manual', 'manual ', '', [], {} ]

      invalid_values.each do |value|
        payload['tax_rounding_mode']['value'] = value
        expect(described_class.parse(payload)).to be_nil
      end
      payload['tax_rounding_mode']['value'] = 'floor'
      invalid_origins.each do |origin|
        payload['tax_rounding_mode']['origin'] = origin
        expect(described_class.parse(payload)).to be_nil
      end
    end

    it '条件ごとに異なるenumを混同しない' do
      {
        'tax_rounding_mode' => 'per_item',
        'discount_rounding_mode' => 'gross',
        'tax_rounding_scope' => 'floor',
        'purchase_adjustment_tax_inclusion' => 'tax_included'
      }.each do |key, value|
        invalid = payload.deep_dup
        invalid[key]['value'] = value

        expect(described_class.parse(invalid)).to be_nil
      end
    end

    it '不正encoding・NUL・controlを除去して有効値へ昇格しない' do
      tokens = [ "floor\0", "floor\n", "floor\t", "floor\u007F", "floor\xFF".b.force_encoding(Encoding::UTF_8) ]

      tokens.each do |token|
        invalid = payload.deep_dup
        invalid['tax_rounding_mode']['value'] = token
        expect(described_class.parse(invalid)).to be_nil

        invalid = payload.deep_dup
        invalid[token] = invalid.delete('tax_rounding_mode')
        expect(described_class.parse(invalid)).to be_nil
      end
    end

    it '巨大値をJSONへ展開したり途中切断せず拒否する' do
      payload['tax_rounding_mode']['value'] = 'x' * 100_000
      expect(JSON).not_to receive(:generate)

      expect(described_class.parse(payload)).to be_nil
    end

    it '循環や深いネストを再帰走査せず拒否する' do
      payload['tax_rounding_mode']['value'] = payload
      expect(JSON).not_to receive(:generate)

      expect(described_class.parse(payload)).to be_nil
    end

    it '全条件の最大tokenと区切り空白を含めてもUTF-8 JSONの4KiB上限内に収まる' do
      payload.each do |key, entry|
        next if key == 'schema_version'

        entry['origin'] = 'application_default'
      end
      json = JSON.generate(described_class.parse(payload).to_h)
      spaced_json = JSON.generate(described_class.parse(payload).to_h, space: ' ', object_nl: ' ')

      aggregate_failures do
        expect(json.encoding).to eq(Encoding::UTF_8)
        expect(json.bytesize).to be <= 4_096
        expect(spaced_json.bytesize).to be <= 4_096
      end
    end
  end

  describe '#to_h' do
    it '取り出したHashと文字列を変更しても内部状態を変更しない' do
      settings = described_class.parse(payload)
      exported = settings.to_h
      exported['tax_rounding_mode']['value'].replace('ceil')
      exported['tax_rounding_mode']['origin'].replace('manual')
      exported.clear

      expect(settings.to_h).to eq(payload)
    end
  end

  describe '#value_for and #origin_for' do
    it '検証済みの文字列をimmutableにする' do
      settings = described_class.parse(payload)

      aggregate_failures do
        expect(settings.value_for('tax_rounding_mode')).to be_frozen
        expect(settings.origin_for('tax_rounding_mode')).to be_frozen
        expect { settings.value_for('tax_rounding_mode') << 'changed' }.to raise_error(FrozenError)
      end
    end
  end
end
