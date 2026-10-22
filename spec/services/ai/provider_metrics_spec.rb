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

    it 'provider errorのmessageは共通の安全な保存境界を使う' do
      message = "Invalid\xFF key\0 for person@example.test at https://example.test/private".force_encoding(Encoding::UTF_8)
      metrics = described_class.build(provider_message: message, request_id: 'request-123')
      detail = ExternalServices.error_detail(provider_message: message, request_id: 'request-123')

      expect(metrics[:provider_message]).to eq(detail[:provider_message_safe])
      expect(metrics[:provider_message]).to be_valid_encoding
      expect(metrics[:provider_message]).not_to match(/[[:cntrl:]]/)
      expect(metrics[:provider_message]).not_to include('person@example.test', 'https://example.test/private')
      expect(JSON.parse(JSON.generate(metrics))).to include('request_id' => 'request-123')
    end

    it '上限超過のmessageと不正な識別子を元の値の一部として保存しない' do
      metrics = described_class.build(
        provider_message: 'あ' * 167,
        model: 'x' * 501,
        request_id: "request\0private",
        response_id: '/private/response',
        fallback_reason: 'person@example.test'
      )

      expect(metrics).to eq(provider_message: '[FILTERED]')
    end

    it '診断の再読込でも安全な原因を保持し任意のpayloadを持ち回らない' do
      diagnostic = {
        schema_version: 'external_service_error_diagnostic_v1',
        nodes: [
          {
            path: 'error',
            code: 'unsupported_value',
            param: 'reasoning.effort',
            message_safe: 'The requested option is not supported.',
            debug: 'private debug'
          }
        ],
        omissions: [],
        raw_response: 'private response'
      }

      metrics = described_class.build(diagnostic: diagnostic)
      restored = described_class.build(JSON.parse(JSON.generate(metrics)))
      expected_nodes = [
        {
          path: 'error',
          code: 'unsupported_value',
          param: 'reasoning.effort',
          message_safe: 'The requested option is not supported.'
        }
      ]

      aggregate_failures do
        expect(restored).to eq(metrics)
        expect(restored.dig(:diagnostic, :nodes)).to eq(expected_nodes)
        expect(restored.to_s).not_to include('private debug', 'private response')
      end
    end

    it '非有限なmetrics数値はJSONへ出さない' do
      metrics = described_class.build(elapsed_ms: Float::NAN, retry_after: Float::INFINITY, token_usage: { total_tokens: 10**100 })

      expect(metrics).to eq({})
      expect { JSON.generate(metrics) }.not_to raise_error
    end

    it '要求modelとreasoning設定を応答modelから分離して保存する' do
      metrics = described_class.build(
        model: 'gpt-returned',
        requested_model: 'gpt-requested',
        reasoning_effort: 'high',
        response_status: 'incomplete',
        incomplete_reason: 'max_output_tokens',
        reasoning: 'private reasoning',
        summary: 'private summary'
      )

      expect(metrics).to eq(
        model: 'gpt-returned',
        requested_model: 'gpt-requested',
        reasoning_effort: 'high',
        response_status: 'incomplete',
        incomplete_reason: 'max_output_tokens'
      )
    end

    %w[none low medium high xhigh max].each do |effort|
      it "reasoning_effortの許可値 #{effort} を保持する" do
        expect(described_class.build(reasoning_effort: effort)).to eq(reasoning_effort: effort)
      end
    end

    it '未知の設定・status・incomplete reasonと不正な要求modelは除外する' do
      metrics = described_class.build(
        requested_model: 'person@example.test',
        reasoning_effort: 'minimal',
        response_status: 'future_status',
        incomplete_reason: 'provider private detail'
      )

      expect(metrics).to eq({})
    end
  end

  describe '.token_usage' do
    it 'reasoningとcached inputを含む既知のtoken数を整数で保持する' do
      usage = described_class.token_usage(
        input_tokens: '10',
        output_tokens: 20,
        total_tokens: 30,
        reasoning_tokens: 8,
        cached_input_tokens: 0,
        private_tokens: 100
      )

      expect(usage).to eq(input_tokens: 10, output_tokens: 20, total_tokens: 30, reasoning_tokens: 8, cached_input_tokens: 0)
      expect(usage.values).to all(be_a(Integer))
    end

    it '不明なusageはゼロを補わず省略する' do
      expect(described_class.token_usage(nil)).to eq({})
    end

    {
      '負数' => -1,
      '小数' => 1.5,
      '整数表現のFloat' => 2.0,
      '小数文字列' => '1.5',
      '不正な文字列' => 'unknown',
      '非有限数' => Float::INFINITY,
      '整数上限超過' => 2**63,
      '文字列の整数上限超過' => (2**63).to_s
    }.each do |label, value|
      it "#{label} のtoken数を除外する" do
        expect(described_class.token_usage(reasoning_tokens: value, cached_input_tokens: value)).to eq({})
      end
    end

    it '整数上限は丸めずに保持する' do
      usage = described_class.token_usage(reasoning_tokens: ((2**63) - 1).to_s)

      expect(usage).to eq(reasoning_tokens: (2**63) - 1)
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
