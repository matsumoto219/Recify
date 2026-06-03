require 'rails_helper'

RSpec.describe Ai::FallbackDecision do
  describe '.call' do
    it 'fallback providerがありfallback可能なerrorならfallbackにする' do
      error = Ai::Errors::ProviderError.new(
        message: 'primary failed',
        error_code: 'ai_primary_failed',
        provider: 'openai'
      )

      decision = described_class.call(error: error, provider: 'openai', fallback_provider: 'fallback_ai')

      aggregate_failures do
        expect(decision.action).to eq(:fallback)
        expect(decision).to be_fallback
        expect(decision.reason).to eq('ai_primary_failed')
        expect(decision.provider).to eq('openai')
        expect(decision.fallback_provider).to eq('fallback_ai')
      end
    end

    it 'fallback providerがなければfailにする' do
      error = Ai::Errors::ProviderError.new(message: 'primary failed', error_code: 'ai_primary_failed')

      decision = described_class.call(error: error, provider: 'openai', fallback_provider: nil)

      expect(decision).to be_fail
    end

    it 'auth errorはfallbackで隠さない' do
      error = Ai::Errors::AuthError.new(message: 'auth failed', error_code: 'external_service_auth_error')

      decision = described_class.call(error: error, provider: 'openai', fallback_provider: 'fallback_ai')

      expect(decision).to be_fail
    end

    it 'invalid responseはfallbackで隠さない' do
      error = Ai::Errors::InvalidResponseError.new(message: 'invalid response', error_code: 'ai_invalid_response')

      decision = described_class.call(error: error, provider: 'openai', fallback_provider: 'fallback_ai')

      expect(decision).to be_fail
    end

    it 'rate limitはfallback候補にする' do
      error = Ai::Errors::RateLimitError.new(message: 'rate limited', error_code: 'ai_api_error', retry_after: 30.0)

      decision = described_class.call(
        error: error,
        provider: 'openai',
        fallback_provider: 'fallback_ai',
        max_retry_after: 10.0
      )

      aggregate_failures do
        expect(decision).to be_fallback
        expect(decision.retry_after).to eq(30.0)
        expect(decision.max_delay_exceeded).to eq(true)
      end
    end

    it 'ProviderErrorのfallbackable flagを利用できる' do
      error = Ai::Errors::ProviderError.new(
        message: 'overloaded',
        error_code: 'provider_overloaded',
        fallbackable: true
      )

      decision = described_class.call(error: error, provider: 'openai', fallback_provider: 'fallback_ai')

      expect(decision).to be_fallback
    end
  end
end
