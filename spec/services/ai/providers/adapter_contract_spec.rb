require 'rails_helper'

RSpec.describe 'AI provider adapter contract' do
  let(:input) { { filtered_content: 'sample receipt text' } }
  let(:request_body) { { model: 'gpt-test', input: 'payload' } }
  let(:safe_metric_keys) do
    %i[
      elapsed_ms
      fallback_provider
      fallback_reason
      fallback_used
      final_provider
      model
      provider
      provider_status
      rate_limited
      response_id
      retry_after_used
      retry_count
      token_usage
      total_retry_sleep_ms
    ]
  end
  let(:unsafe_metric_keys) do
    %i[
      api_key
      authorization
      endpoint
      headers
      prompt
      raw_headers
      raw_response
      request_body
      secret
    ]
  end

  def openai_response(response_id: 'resp_contract')
    {
      'id' => response_id,
      'model' => 'gpt-test',
      'usage' => {
        'input_tokens' => 10,
        'output_tokens' => 8,
        'total_tokens' => 18
      },
      'output_text' => {
        is_receipt: true,
        document_type: 'receipt',
        rejection_reason: nil,
        store: {},
        purchase: {},
        payment: {},
        items: [],
        receipt_adjustments: [],
        needs_review: false,
        review_reasons: []
      }.to_json
    }
  end

  describe Ai::Providers::Openai::Client do
    subject(:adapter) { described_class.new }

    before do
      allow(Ai::Providers::Openai::RequestBuilder).to receive(:build).with(input).and_return(request_body)
    end

    it 'call(input) は ProviderResult を返す' do
      allow(adapter).to receive(:post_request).with(request_body).and_return(openai_response)

      result = adapter.call(input)

      aggregate_failures do
        expect(result).to be_a(Ai::ProviderResult)
        expect(result.provider).to eq('openai')
        expect(result.payload).to include(success: true)
        expect(result.metrics).to include(
          provider: 'openai',
          model: 'gpt-test',
          response_id: 'resp_contract',
          provider_status: '200',
          token_usage: {
            input_tokens: 10,
            output_tokens: 8,
            total_tokens: 18
          }
        )
      end
    end

    it 'metricsにprompt/raw response/headers/secretsを含めない' do
      allow(adapter).to receive(:post_request).with(request_body).and_return(openai_response)

      result = adapter.call(input)

      aggregate_failures do
        expect(result.metrics.keys - safe_metric_keys).to be_empty
        expect(result.metrics.keys & unsafe_metric_keys).to be_empty
      end
    end

    it 'provider failure は ProviderError 系へ正規化して送出する' do
      allow(adapter).to receive(:post_request).with(request_body).and_raise(
        Ai::Errors::ProviderError.new(
          message: 'OpenAI API retryable server error: 500',
          error_code: 'ai_api_error',
          provider: 'openai',
          category: :server_error,
          retryable: true,
          fallbackable: true,
          provider_status: '500',
          metrics: {
            provider: 'openai',
            provider_status: '500'
          }
        )
      )

      expect do
        adapter.call(input)
      end.to raise_error(Ai::Errors::ProviderError) { |error|
        aggregate_failures do
          expect(error.provider).to eq('openai')
          expect(error.category).to eq(:server_error)
          expect(error.retryable?).to eq(true)
          expect(error.fallbackable?).to eq(true)
          expect(error.metrics.keys - safe_metric_keys).to be_empty
        end
      }
    end

    it 'retry policyを公開し、executorが利用できる' do
      expect(adapter.retry_policy).to be_a(Ai::RetryPolicy)
    end
  end
end
