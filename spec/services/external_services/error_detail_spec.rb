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

    it '長いprovider quota識別語を保持して元の分類根拠から判定する' do
      detail = described_class.build(
        service: :ocr,
        provider: 'azure_document_intelligence',
        http_status: 403,
        body: { error: { code: '403', message: 'QuotaExceededForSubscription' } }
      )

      expect(detail).to include(provider_message_safe: 'QuotaExceededForSubscription', quota_exceeded: true)
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

    it '不正UTF-8や制御文字を含むmessageでもJSON保存可能な詳細を返す' do
      detail = described_class.build(
        http_status: 403,
        provider_error_code: 'invalid_api_key',
        provider_message: "Invalid\xFF API\0 key\n\tprovided".force_encoding(Encoding::UTF_8)
      )

      expect(detail[:provider_message_safe]).to eq('Invalid API key provided')
      expect(detail[:provider_message_safe]).to be_valid_encoding
      expect(JSON.parse(JSON.generate(detail))).to include('provider_error_code' => 'invalid_api_key')
      expect(detail[:provider_message_safe]).not_to match(/[[:cntrl:]]/)
    end

    it 'messageの上限を超えた場合は文字の途中を切断せず固定表示へ置き換える' do
      detail = described_class.build(provider_message: 'あ' * 167, http_status: 403)

      expect(detail).to include(http_status: 403, provider_message_safe: '[FILTERED]')
      expect(detail[:provider_message_safe].bytesize).to be <= 500
    end

    %i[provider provider_error_code provider_error_type request_id model region policy_id phase source reason].each do |key|
      it "#{key}の不正型・機密値・上限超過を丸ごと除外する" do
        [ 'x' * 501, "invalid\0value", 'person@example.test', '/private/value', { secret: 'value' } ].each do |value|
          detail = described_class.build(**{ key => value }, http_status: 403)

          expect(detail).not_to have_key(key)
          expect(detail[:http_status]).to eq(403)
        end
      end
    end

    it 'header由来の識別子にも同じ保存境界を適用する' do
      detail = described_class.build(
        headers: {
          'x-request-id' => "request\xFF".force_encoding(Encoding::UTF_8),
          'x-ms-region' => "Japan\0East",
          'policy-id' => '/private/policy'
        }
      )

      expect(detail.keys).not_to include(:request_id, :region, :policy_id)
    end

    it '保存できない構造化codeを削除してもmessageだけのquota判定へ昇格しない' do
      detail = described_class.build(
        provider_error_code: 'x' * 5_000,
        provider_message: 'Quota exceeded',
        http_status: 403
      )

      expect(detail).not_to have_key(:provider_error_code)
      expect(detail[:quota_exceeded]).not_to eq(true)
    end

    it 'safe metadataの再正規化で表示値や識別子を変えない' do
      first = described_class.build(provider_message: 'Provider failed for person@example.test', request_id: 'req-123')
      second = described_class.build(**first)

      expect(second).to eq(first)
    end

    %i[provider_message provider_error_code provider_error_type].each do |key|
      it "#{key}のUTF-16文字列を分類してもencoding例外にしない" do
        value = (key == :provider_message ? 'Quota exceeded' : 'insufficient_quota').encode(Encoding::UTF_16LE)
        detail = described_class.build(**{ key => value }, http_status: 403)

        expect(detail[:quota_exceeded]).to eq(true)
        expect { JSON.generate(detail) }.not_to raise_error
      end

      it "#{key}の不正UTF-8を元のprovider errorに代わる例外へしない" do
        value = "invalid\xFF".force_encoding(Encoding::UTF_8)
        detail = described_class.build(**{ key => value }, http_status: 403)

        expect(detail[:quota_exceeded]).not_to eq(true)
        expect { JSON.generate(detail) }.not_to raise_error
      end
    end

    it '非有限数や桁超過を保存してJSON生成を失敗させない' do
      detail = described_class.build(latency_ms: Float::NAN, retry_after: Float::INFINITY, poll_count: 10**100)

      expect(detail.keys).not_to include(:latency_ms, :retry_after, :retry_after_at, :poll_count)
      expect { JSON.generate(detail) }.not_to raise_error
    end
  end
end
