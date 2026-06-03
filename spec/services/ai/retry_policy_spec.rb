require 'rails_helper'

RSpec.describe Ai::RetryPolicy do
  subject(:policy) do
    described_class.new(
      max_retries: 2,
      backoff_policy: Ai::BackoffPolicy.new(base_delay: 1.0, max_delay: 10.0, jitter: -> { 0.0 })
    )
  end

  describe '#retryable?' do
    it 'timeout/network系はretry対象にする' do
      aggregate_failures do
        expect(policy.retryable?(Net::OpenTimeout.new('timeout'))).to eq(true)
        expect(policy.retryable?(Net::ReadTimeout.new('timeout'))).to eq(true)
      end
    end

    it 'rate limitはretry対象にする' do
      error = Ai::Errors::RateLimitError.new(message: 'rate limited', error_code: 'ai_api_error')

      expect(policy.retryable?(error)).to eq(true)
    end

    it 'ai_api_errorは既存挙動どおりretry対象にする' do
      error = Ai::Errors::ProviderError.new(message: 'server error', error_code: 'ai_api_error')

      expect(policy.retryable?(error)).to eq(true)
    end

    it 'auth/invalid responseはretry対象にしない' do
      aggregate_failures do
        expect(policy.retryable?(Ai::Errors::AuthError.new(message: 'auth', error_code: 'external_service_auth_error'))).to eq(false)
        expect(policy.retryable?(Ai::Errors::InvalidResponseError.new(message: 'invalid', error_code: 'ai_invalid_response'))).to eq(false)
      end
    end
  end

  describe '#delay_for' do
    it 'backoff policyの計算を使う' do
      error = Ai::Errors::ProviderError.new(message: 'server error', error_code: 'ai_api_error')

      expect(policy.delay_for(attempt: 2, error: error)).to eq(2.0)
    end

    it 'errorのRetry-Afterをbackoff policyへ渡す' do
      error = Ai::Errors::RateLimitError.new(message: 'rate limited', error_code: 'ai_api_error', retry_after: 3.0)

      expect(policy.delay_for(attempt: 1, error: error)).to eq(3.0)
    end
  end
end
