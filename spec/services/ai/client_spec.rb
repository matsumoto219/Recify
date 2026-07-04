require 'rails_helper'

RSpec.describe Ai::Client do
  let(:input) { { filtered_content: 'sample receipt text' } }
  let(:primary_provider) { :openai }
  let(:fallback_provider) { :fallback_ai }
  let(:primary_client) { instance_double('PrimaryProviderClient') }
  let(:fallback_client) { instance_double('FallbackProviderClient') }

  subject(:client) do
    described_class.new(
      primary_provider: primary_provider,
      fallback_provider: fallback_provider
    )
  end

  def provider_result(payload, provider:)
    Ai::ProviderResult.new(
      provider: provider,
      model: payload.dig(:meta, :model),
      payload: payload,
      metrics: payload.dig(:meta, :metrics),
      response_id: payload.dig(:meta, :response_id)
    )
  end

  before do
    allow(Ai::ProviderRegistry).to receive(:fetch).with(primary_provider).and_return(primary_client)
    allow(Ai::ProviderRegistry).to receive(:fetch).with(fallback_provider).and_return(fallback_client)
  end

  describe '#call' do
    context 'primary provider が成功する場合' do
      let(:primary_result) do
        {
          success: true,
          receipt_attributes: { store_name: 'OpenAI Store' },
          receipt_items_attributes: []
        }
      end

      it 'primary の結果をそのまま返し fallback を使わない' do
        allow(primary_client).to receive(:call).with(input).and_return(provider_result(primary_result, provider: primary_provider))
        allow(fallback_client).to receive(:call)

        result = client.call(input)

        aggregate_failures do
          expect(result).to eq(primary_result)
          expect(primary_client).to have_received(:call).with(input)
          expect(fallback_client).not_to have_received(:call)
          expect(result.dig(:meta, :metrics)).to include(
            fallback_used: false,
            fallback_provider: 'fallback_ai',
            final_provider: 'openai'
          )
        end
      end
    end

    context 'primary が timeout し fallback が成功する場合' do
      let(:fallback_result) do
        {
          success: true,
          receipt_attributes: { store_name: 'Fallback Store' },
          receipt_items_attributes: [],
          meta: { provider: 'fallback_ai' }
        }
      end

      it 'fallback の結果を返し fallback_used を付与する' do
        allow(primary_client).to receive(:call).with(input).and_raise(Ai::Errors::TimeoutError.new(message: 'timeout'))
        allow(fallback_client).to receive(:call).with(input).and_return(provider_result(fallback_result, provider: fallback_provider))

        result = client.call(input)

        aggregate_failures do
          expect(primary_client).to have_received(:call).with(input)
          expect(fallback_client).to have_received(:call).with(input)
          expect(result[:success]).to eq(true)
          expect(result.dig(:meta, :fallback_used)).to eq(true)
          expect(result.dig(:meta, :fallback_provider)).to eq('fallback_ai')
          expect(result.dig(:meta, :fallback_reason)).to eq('ai_primary_failed')
          expect(result.dig(:meta, :provider)).to eq('fallback_ai')
          expect(result.dig(:meta, :metrics)).to include(
            fallback_used: true,
            fallback_provider: 'fallback_ai',
            fallback_reason: 'ai_primary_failed',
            final_provider: 'fallback_ai'
          )
        end
      end
    end

    context 'primary が fallback対象の ProviderError を返し fallback が成功する場合' do
      let(:fallback_result) do
        {
          success: true,
          receipt_attributes: { store_name: 'Fallback Store' },
          receipt_items_attributes: []
        }
      end

      it 'fallback を実行する' do
        error = Ai::Errors::ProviderError.new(message: 'primary failed', error_code: 'ai_primary_failed')
        allow(primary_client).to receive(:call).with(input).and_raise(error)
        allow(fallback_client).to receive(:call).with(input).and_return(provider_result(fallback_result, provider: fallback_provider))

        result = client.call(input)

        aggregate_failures do
          expect(primary_client).to have_received(:call).with(input)
          expect(fallback_client).to have_received(:call).with(input)
          expect(result[:success]).to eq(true)
          expect(result.dig(:meta, :fallback_used)).to eq(true)
          expect(result.dig(:meta, :metrics)).to include(
            fallback_used: true,
            fallback_provider: 'fallback_ai',
            fallback_reason: 'ai_primary_failed',
            final_provider: 'fallback_ai'
          )
        end
      end
    end

    context 'primary が fallback対象外のエラーを返す場合' do
      it 'provider adapterがhashを返した場合は契約違反として扱う' do
        allow(primary_client).to receive(:call).with(input).and_return(success: true)
        allow(fallback_client).to receive(:call)

        expect do
          client.call(input)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.error_code).to eq('ai_invalid_response')
            expect(error.category).to eq(:invalid_response)
            expect(fallback_client).not_to have_received(:call)
          end
        }
      end

      it 'AuthError 時は fallback で隠さずそのまま送出する' do
        allow(primary_client).to receive(:call).with(input).and_raise(Ai::Errors::AuthError.new(message: 'auth failed', error_code: 'ai_auth_error'))
        allow(fallback_client).to receive(:call)

        expect do
          client.call(input)
        end.to raise_error(Ai::Errors::AuthError, 'auth failed')

        expect(fallback_client).not_to have_received(:call)
      end

      it 'before_provider_callは呼び出したprovider分だけ実行しfallback未到達分は実行しない' do
        callback_calls = 0
        allow(primary_client).to receive(:call)
          .with(input, before_provider_call: kind_of(Proc)) do |_input, before_provider_call:|
            before_provider_call.call
            raise Ai::Errors::AuthError.new(message: 'auth failed', error_code: 'ai_auth_error')
          end
        allow(fallback_client).to receive(:call)

        expect do
          client.call(input, before_provider_call: -> { callback_calls += 1 })
        end.to raise_error(Ai::Errors::AuthError)

        aggregate_failures do
          expect(callback_calls).to eq(1)
          expect(primary_client).to have_received(:call).with(input, before_provider_call: kind_of(Proc)).once
          expect(fallback_client).not_to have_received(:call)
        end
      end

      it 'InvalidResponseError 時は fallback で隠さずそのまま送出する' do
        allow(primary_client).to receive(:call).with(input).and_raise(Ai::Errors::InvalidResponseError.new(message: 'invalid response'))
        allow(fallback_client).to receive(:call)

        expect do
          client.call(input)
        end.to raise_error(Ai::Errors::InvalidResponseError, 'invalid response')

        expect(fallback_client).not_to have_received(:call)
      end
    end

    context 'fallback provider が未設定の場合' do
      let(:fallback_provider) { nil }

      before do
        allow(Ai::ProviderRegistry).to receive(:fetch).with(nil).and_return(nil)
      end

      it 'primary 失敗時に error result を返す' do
        error = Ai::Errors::ProviderError.new(
          message: 'primary failed',
          error_code: 'ai_primary_failed',
          metrics: {
            provider: 'openai',
            retry_count: 2,
            retry_after_used: true,
            rate_limited: true
          }
        )
        allow(primary_client).to receive(:call).with(input).and_raise(error)

        result = client.call(input)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ai_primary_failed')
          expect(result.dig(:meta, :primary_error_code)).to eq('ai_primary_failed')
          expect(result.dig(:meta, :fallback_used)).to eq(false)
          expect(result.dig(:meta, :metrics)).to include(
            provider: 'openai',
            retry_count: 2,
            retry_after_used: true,
            rate_limited: true,
            fallback_used: false,
            fallback_reason: 'ai_primary_failed',
            final_provider: 'openai'
          )
        end
      end
    end

    context 'fallback も失敗する場合' do
      it 'error result を返す' do
        primary_error = Ai::Errors::ProviderError.new(message: 'primary failed', error_code: 'ai_primary_failed')
        fallback_error = Ai::Errors::ProviderError.new(message: 'fallback failed', error_code: 'ai_fallback_failed')

        allow(primary_client).to receive(:call).with(input).and_raise(primary_error)
        allow(fallback_client).to receive(:call).with(input).and_raise(fallback_error)

        result = client.call(input)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ai_fallback_failed')
          expect(result.dig(:meta, :primary_error_code)).to eq('ai_primary_failed')
          expect(result.dig(:meta, :fallback_error_code)).to eq('ai_fallback_failed')
          expect(result.dig(:meta, :fallback_used)).to eq(true)
        end
      end

      it 'fallback側の利用上限超過はprovider失敗に変換せず送出する' do
        primary_error = Ai::Errors::ProviderError.new(message: 'primary failed', error_code: 'ai_primary_failed')
        quota_error = Usage::LimitExceeded.new(
          key: 'ai_jobs_per_day',
          limit: 1,
          used: 1,
          requested: 1
        )

        allow(primary_client).to receive(:call).with(input).and_raise(primary_error)
        allow(fallback_client).to receive(:call).with(input).and_raise(quota_error)

        expect { client.call(input) }.to raise_error(Usage::LimitExceeded)
      end

      it 'provider error detailをsafeな共通形式で返す' do
        primary_error = Ai::Errors::ProviderError.new(
          message: 'primary quota failed with prompt=store secrets',
          error_code: 'ai_quota_exceeded',
          provider: primary_provider,
          category: :billing_quota,
          fallbackable: true,
          provider_status: 429,
          provider_error_code: 'insufficient_quota',
          provider_error_type: 'insufficient_quota',
          provider_message: 'Quota exceeded for sk-secret-token-1234567890',
          request_id: 'req_primary',
          retry_after: 30,
          quota_exceeded: true,
          phase: 'ai_request',
          metrics: {
            model: 'gpt-test',
            prompt: 'PROMPT MUST NOT BE STORED',
            raw_body: '{"error":"RAW BODY"}'
          }
        )
        fallback_error = Ai::Errors::ProviderError.new(
          message: 'fallback failed',
          error_code: 'ai_fallback_failed',
          provider: fallback_provider,
          category: :server_error,
          provider_status: 500,
          provider_error_code: 'server_error',
          provider_error_type: 'server_error',
          provider_message: 'temporary provider error',
          request_id: 'req_fallback',
          phase: 'fallback',
          metrics: {
            model: 'fallback-model',
            headers: { authorization: 'Bearer secret' }
          }
        )

        allow(primary_client).to receive(:call).with(input).and_raise(primary_error)
        allow(fallback_client).to receive(:call).with(input).and_raise(fallback_error)

        result = client.call(input)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ai_fallback_failed')
          expect(result.dig(:meta, :final_provider)).to eq('fallback_ai')
          expect(result.dig(:meta, :primary_error_message)).to eq('Quota exceeded for [FILTERED]')
          expect(result.dig(:meta, :primary_error_detail)).to include(
            service: 'ai',
            provider: 'openai',
            phase: 'ai_request',
            http_status: 429,
            provider_error_code: 'insufficient_quota',
            provider_error_type: 'insufficient_quota',
            provider_message_safe: 'Quota exceeded for [FILTERED]',
            request_id: 'req_primary',
            retry_after: 30,
            model: 'gpt-test',
            quota_exceeded: true
          )
          expect(result.dig(:meta, :fallback_error_detail)).to include(
            service: 'ai',
            provider: 'fallback_ai',
            phase: 'fallback',
            http_status: 500,
            provider_error_code: 'server_error',
            request_id: 'req_fallback',
            model: 'fallback-model'
          )
          expect(result.dig(:meta, :final_error_detail)).to eq(result.dig(:meta, :fallback_error_detail))
          expect(result.to_s).not_to include('sk-secret-token')
          expect(result.to_s).not_to include('PROMPT MUST NOT BE STORED')
          expect(result.to_s).not_to include('RAW BODY')
          expect(result.to_s).not_to include('authorization')
        end
      end
    end

    context 'ProviderError に error_code が無い場合' do
      let(:fallback_provider) { nil }

      before do
        allow(Ai::ProviderRegistry).to receive(:fetch).with(nil).and_return(nil)
      end

      it 'ai_primary_failed を primary_error_code として使う' do
        error = Ai::Errors::ProviderError.new(message: 'primary failed')
        allow(primary_client).to receive(:call).with(input).and_raise(error)

        result = client.call(input)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result.dig(:meta, :primary_error_code)).to eq('ai_primary_failed')
          expect(result.dig(:meta, :fallback_used)).to eq(false)
        end
      end
    end

    context 'primary の TimeoutError は fallback判定用 ProviderError に変換される' do
      let(:fallback_provider) { nil }

      before do
        allow(Ai::ProviderRegistry).to receive(:fetch).with(nil).and_return(nil)
      end

      it 'primary_error_code に ai_primary_failed を入れて error result を返す' do
        allow(primary_client).to receive(:call).with(input).and_raise(
          Ai::Errors::TimeoutError.new(
            message: 'timeout with prompt=secret',
            provider: primary_provider,
            provider_error_code: 'timeout',
            provider_message: 'execution expired',
            request_id: 'req_timeout',
            phase: 'ai_request'
          )
        )

        result = client.call(input)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ai_primary_failed')
          expect(result.dig(:meta, :primary_error_code)).to eq('ai_primary_failed')
          expect(result.dig(:meta, :primary_error_message)).to eq('execution expired')
          expect(result.dig(:meta, :primary_error_detail)).to include(
            service: 'ai',
            provider: 'openai',
            phase: 'ai_request',
            provider_error_code: 'timeout',
            provider_message_safe: 'execution expired',
            request_id: 'req_timeout'
          )
          expect(result.dig(:meta, :fallback_used)).to eq(false)
          expect(result.to_s).not_to include('prompt=secret')
        end
      end
    end
  end
end
