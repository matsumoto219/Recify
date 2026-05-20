require 'rails_helper'

RSpec.describe Ai::Providers::Openai::RequestBuilder do
  describe '.build' do
    let(:input) { { filtered_content: 'sample receipt text' } }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("OPENAI_AI_MODEL").and_return("gpt-test")
    end

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
        expect(request.dig(:input, 0, :content, 0, :text)).to include("Output MUST be a valid JSON object.")
        expect(request.dig(:input, 1, :content, 0, :text)).to include("Input JSON:")
      end
    end

    it '商品名AI補完時のreasoning指定を維持する' do
      request = described_class.build(
        meta: { ai_name_completion_enabled: true }
      )

      expect(request[:reasoning]).to eq(effort: "medium")
    end
  end
end
