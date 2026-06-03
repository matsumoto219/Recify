require 'rails_helper'

RSpec.describe Ai::ProviderResult do
  describe '#initialize' do
    it 'provider adapterの成功結果を共通schemaへ正規化する' do
      payload = {
        success: true,
        receipt_attributes: { store_name: 'Store' },
        meta: { prompt: 'payload meta is not provider contract' }
      }

      result = described_class.new(
        provider: :openai,
        model: 'gpt-test',
        response_id: 'resp_123',
        payload: payload,
        metrics: {
          retry_count: 1,
          retry_after_used: true,
          raw_response: 'do-not-keep'
        }
      )

      aggregate_failures do
        expect(result.provider).to eq('openai')
        expect(result.model).to eq('gpt-test')
        expect(result.response_id).to eq('resp_123')
        expect(result.payload).to eq(payload)
        expect(result).to be_success
        expect(result.metrics).to include(
          provider: 'openai',
          model: 'gpt-test',
          response_id: 'resp_123',
          retry_count: 1,
          retry_after_used: true
        )
        expect(result.metrics).not_to have_key(:raw_response)
      end
    end

    it 'metrics内のresponse_idを利用できる' do
      result = described_class.new(
        provider: 'openai',
        payload: { success: false },
        metrics: { response_id: 'resp_from_metrics' }
      )

      expect(result.response_id).to eq('resp_from_metrics')
    end
  end
end
