require 'rails_helper'

RSpec.describe Ai::Providers::Openai::RequestBuilder do
  describe '.build' do
    let(:input) { { filtered_content: 'sample receipt text' } }

    it 'Structured Outputs json_schema formatを使う' do
      request = described_class.build(input)
      format = request.dig(:text, :format)

      aggregate_failures do
        expect(format[:type]).to eq("json_schema")
        expect(format[:name]).to eq("recify_receipt_analysis_v1")
        expect(format[:strict]).to eq(true)
        expect(format[:schema]).to eq(Ai::ReceiptAnalysisSchema.to_json_schema)
        expect(format).not_to include(type: "json_object")
      end
    end

    it 'schema非対応provider向けのprompt入力構造は変更しない' do
      request = described_class.build(input)

      aggregate_failures do
        expect(request[:input]).to be_an(Array)
        expect(request.dig(:input, 0, :content, 0, :text)).to include("You MUST output only a valid JSON object")
        expect(request.dig(:input, 0, :content, 0, :text)).to include("Do NOT output anything except JSON.")
        expect(request.dig(:input, 1, :content, 0, :text)).to include("Input JSON:")
      end
    end

    it 'promptへ提示する同じ候補IDと関係IDで応答schemaを制限する' do
      option_id = "store_option_#{'a' * 32}"
      relation_id = "store_relation_#{'b' * 32}"
      input[:store] = {
        name_options: {
          schema_version: 'store_name_options_v2',
          options: [ { option_id: option_id, value: '候補の店舗名' } ],
          relations: [ { relation_id: relation_id } ]
        }
      }
      request = described_class.build(input.deep_stringify_keys)
      selection = request.dig(:text, :format, :schema, 'properties', 'store', 'properties', 'store_name_selection')

      aggregate_failures do
        expect(selection.dig('properties', 'option_id', 'enum')).to eq([ option_id, nil ])
        expect(selection.dig('properties', 'relations', 'required')).to eq([ relation_id ])
        expect(selection.dig('properties', 'relations', 'properties').keys).to eq([ relation_id ])
        expect(selection.dig('properties', 'relations', 'additionalProperties')).to be(false)
        expect(request.dig(:input, 1, :content, 0, :text)).to include(option_id, relation_id, '候補の店舗名')
        expect(request.dig(:text, :format, :schema).to_json).not_to include('候補の店舗名')
      end
    end

    it '商品名AI補完OFFでは固定した通常の推論強度を送る' do
      config = ExternalServices.runtime_config_snapshot.ai.with(model: 'custom-model', reasoning_effort: 'max')
      request = described_class.build(input, runtime_config: config)

      aggregate_failures do
        expect(request[:model]).to eq('custom-model')
        expect(request[:reasoning]).to eq(effort: 'max')
        expect(request).not_to have_key(:max_output_tokens)
      end
    end

    it '商品名AI補完ONでは固定した補完用の推論強度を送る' do
      config = ExternalServices.runtime_config_snapshot.ai.with(name_completion_reasoning_effort: 'xhigh')
      request = described_class.build(
        { meta: { ai_name_completion_enabled: true } },
        runtime_config: config
      )

      expect(request[:reasoning]).to eq(effort: 'xhigh')
    end

    it '文字列trueで商品名AI補完用の推論強度へ切り替えない' do
      request = described_class.build({ meta: { ai_name_completion_enabled: 'true' } })

      expect(request[:reasoning]).to eq(effort: 'low')
    end

    it 'モデルと推論強度の対応範囲を独自に制限しない' do
      config = ExternalServices.runtime_config_snapshot.ai.with(model: 'ft:custom:model', reasoning_effort: 'max')

      expect(described_class.build(input, runtime_config: config)).to include(
        model: 'ft:custom:model', reasoning: { effort: 'max' }
      )
    end
  end
end
