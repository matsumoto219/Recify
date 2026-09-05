require 'rails_helper'

RSpec.describe ExternalServices::ErrorDetail do
  include ActiveSupport::Testing::TimeHelpers

  describe '.build' do
    it 'provider error body/headerから保存可能な詳細だけを抽出する' do
      detail = nil
      travel_to(Time.zone.parse('2026-05-23 10:00:00')) do
        detail = described_class.build(
          service: :ocr,
          provider: 'azure_document_intelligence',
          phase: :submit,
          http_status: 403,
          body: {
            error: {
              code: '403',
              message: 'Out of call volume quota for FormRecognizer F0 pricing tier. Bearer sk-secret-value'
            }
          },
          headers: {
            'retry-after' => '120',
            'apim-request-id' => 'request-123',
            'x-ms-region' => 'Japan East',
            'policy-id' => 'formrec_freetier_quota_id',
            'Ocp-Apim-Subscription-Key' => 'secret-key'
          }
        )
      end

      aggregate_failures do
        expect(detail).to include(
          service: 'ocr',
          provider: 'azure_document_intelligence',
          phase: 'submit',
          http_status: 403,
          provider_error_code: '403',
          request_id: 'request-123',
          region: 'Japan East',
          policy_id: 'formrec_freetier_quota_id',
          retry_after: 120.0,
          retry_after_at: '2026-05-23T10:02:00+09:00',
          quota_exceeded: true
        )
        expect(detail[:provider_message_safe]).to include('Out of call volume quota')
        expect(detail[:provider_message_safe]).not_to include('sk-secret-value')
        expect(detail).not_to have_key(:headers)
      end
    end

    it 'OpenAI形式のerror objectからcode/type/messageを安全に抽出する' do
      detail = described_class.build(
        service: :ai,
        provider: 'openai',
        phase: :ai_request,
        http_status: '429',
        model: 'gpt-test',
        body: {
          error: {
            type: 'insufficient_quota',
            code: 'insufficient_quota',
            message: 'You exceeded your current quota.'
          }
        },
        headers: {
          'x-request-id' => 'req_openai',
          'retry-after' => '3'
        }
      )

      expect(detail).to include(
        service: 'ai',
        provider: 'openai',
        phase: 'ai_request',
        http_status: 429,
        provider_error_code: 'insufficient_quota',
        provider_message_safe: 'You exceeded your current quota.',
        request_id: 'req_openai',
        retry_after: 3.0,
        model: 'gpt-test',
        quota_exceeded: true,
        rate_limited: true
      )
    end

    it 'nilや不正なbodyでも壊れず保存禁止情報を含めない' do
      detail = described_class.build(
        service: nil,
        provider: nil,
        body: 'Authorization: Bearer secret-token-value',
        headers: nil,
        retry_after: 'not-a-date'
      )

      aggregate_failures do
        expect(detail[:provider_message_safe]).to include('[FILTERED]')
        expect(detail[:retry_after]).to be_nil
        expect(detail.keys).not_to include(:authorization, :api_key, :raw_response, :body)
      end
    end

    it '表示用にfilterされたquota messageも元の分類根拠から判定する' do
      detail = described_class.build(
        service: :ocr,
        provider: 'azure_document_intelligence',
        http_status: 403,
        body: { error: { code: '403', message: 'QuotaExceededForSubscription' } }
      )

      expect(detail).to include(provider_message_safe: '[FILTERED]', quota_exceeded: true)
      expect(detail[:auth_error]).not_to eq(true)
      expect(detail).not_to have_key(:provider_message)
    end

    it '明示されたprovider codeを本文の表示内容と独立して分類する' do
      detail = described_class.build(
        service: :ai,
        provider: 'openai',
        http_status: 429,
        provider_error_code: 'insufficient_quota',
        provider_message_safe: '[FILTERED]'
      )

      expect(detail[:quota_exceeded]).to eq(true)
    end

    it 'provider typeだけにあるquota分類を保持する' do
      detail = described_class.build(
        service: :ai,
        provider: 'openai',
        http_status: 429,
        body: { error: { code: 'error', type: 'insufficient_quota', message: '[FILTERED]' } }
      )

      expect(detail[:quota_exceeded]).to eq(true)
    end

    it 'quotaを含む説明文より構造化された認証エラーcodeを優先する' do
      detail = described_class.build(
        service: :ocr,
        provider: 'azure_document_intelligence',
        http_status: 403,
        body: { error: { code: 'invalid_api_key', message: 'Check quota and API key settings.' } }
      )

      expect(detail[:quota_exceeded]).not_to eq(true)
      expect(detail[:auth_error]).to eq(true)
    end

    [
      'Quota was not exceeded; invalid API key.',
      'No quota exceeded; permission denied.',
      'Check your quota settings.',
      'Quota is available.',
      'UnknownQuotaFailure'
    ].each do |message|
      it "quotaを確定できない説明をquota exceededへ分類しない: #{message}" do
        detail = described_class.build(http_status: 403, body: { error: { code: '403', message: message } })

        expect(detail[:quota_exceeded]).not_to eq(true)
      end
    end

    it 'rate-limit codeにquotaという語が併記されても429をquotaへ変えない' do
      detail = described_class.build(
        http_status: 429,
        body: { error: { code: 'rate_limit_exceeded', message: 'Rate limit exceeded; check quota settings.' } }
      )

      expect(detail[:quota_exceeded]).not_to eq(true)
      expect(detail[:rate_limited]).to eq(true)
    end
  end
end
