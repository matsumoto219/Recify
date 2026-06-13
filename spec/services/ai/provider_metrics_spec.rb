require 'rails_helper'

RSpec.describe Ai::ProviderMetrics do
  describe '.build' do
    it 'AI provider metricsを保存可能なallowlistへ正規化する' do
      metrics = described_class.build(
        provider: :openai,
        model: 'gpt-test',
        elapsed_ms: '123',
        retry_count: 2,
        retry_after_used: true,
        total_retry_sleep_ms: 3000,
        rate_limited: false,
        provider_status: 200,
        provider_error_code: :insufficient_quota,
        provider_error_type: :insufficient_quota,
        provider_message: 'Quota exceeded',
        request_id: 'req_123',
        retry_after: '3',
        quota_exceeded: true,
        auth_error: false,
        phase: :ai_request,
        token_usage: {
          input_tokens: '10',
          output_tokens: 20,
          total_tokens: 30,
          raw_response: 'do-not-store'
        },
        response_id: 'resp_123',
        fallback_used: true,
        fallback_provider: :backup,
        fallback_reason: :ai_primary_failed,
        prompt: 'do-not-store'
      )

      expect(metrics).to eq(
        provider: 'openai',
        model: 'gpt-test',
        elapsed_ms: 123.0,
        retry_count: 2,
        retry_after_used: true,
        total_retry_sleep_ms: 3000,
        rate_limited: false,
        provider_status: '200',
        provider_error_code: 'insufficient_quota',
        provider_error_type: 'insufficient_quota',
        provider_message: 'Quota exceeded',
        request_id: 'req_123',
        retry_after: 3.0,
        quota_exceeded: true,
        auth_error: false,
        phase: 'ai_request',
        token_usage: {
          input_tokens: 10.0,
          output_tokens: 20,
          total_tokens: 30
        },
        response_id: 'resp_123',
        fallback_used: true,
        fallback_provider: 'backup',
        fallback_reason: 'ai_primary_failed'
      )
    end
  end

  describe '.merge' do
    it 'nilの上書き値で既存metricsを消さない' do
      metrics = described_class.merge(
        { provider: 'openai', retry_count: 1 },
        { provider: nil, retry_after_used: false }
      )

      expect(metrics).to include(
        provider: 'openai',
        retry_count: 1,
        retry_after_used: false
      )
    end
  end
end
