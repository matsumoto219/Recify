require 'rails_helper'

RSpec.describe ExternalServices::ErrorDetail do
  describe '.build' do
    it 'provider error body/headerから保存可能な詳細だけを抽出する' do
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
          'Ocp-Apim-Subscription-Key' => 'secret-key'
        }
      )

      aggregate_failures do
        expect(detail).to include(
          service: 'ocr',
          provider: 'azure_document_intelligence',
          phase: 'submit',
          http_status: 403,
          provider_error_code: '403',
          request_id: 'request-123',
          region: 'Japan East',
          retry_after: 120.0,
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
  end
end
