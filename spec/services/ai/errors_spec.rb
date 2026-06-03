require 'rails_helper'

RSpec.describe Ai::Errors::ProviderError do
  it 'provider errorを共通schemaへ正規化する' do
    cause = StandardError.new('provider specific error')
    error = described_class.new(
      message: 'rate limited',
      error_code: 'ai_api_error',
      provider: :openai,
      category: :rate_limit,
      retryable: true,
      fallbackable: true,
      retry_after: 2.5,
      provider_status: 429,
      cause: cause,
      metrics: {
        retry_count: 2,
        retry_after_used: true,
        headers: { authorization: 'secret' }
      }
    )

    aggregate_failures do
      expect(error.message).to eq('rate limited')
      expect(error.error_code).to eq('ai_api_error')
      expect(error.provider).to eq(:openai)
      expect(error.category).to eq(:rate_limit)
      expect(error).to be_retryable
      expect(error).to be_fallbackable
      expect(error.retry_after).to eq(2.5)
      expect(error.provider_status).to eq(429)
      expect(error.cause).to eq(cause)
      expect(error.metrics).to include(
        provider: 'openai',
        retry_count: 2,
        retry_after_used: true,
        provider_status: '429'
      )
      expect(error.metrics).not_to have_key(:headers)
    end
  end

  it 'retryable/fallbackableは明示されない限りfalseにする' do
    error = described_class.new(error_code: 'ai_invalid_response')

    expect(error).not_to be_retryable
    expect(error).not_to be_fallbackable
  end
end
