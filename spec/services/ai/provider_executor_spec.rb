require 'rails_helper'

RSpec.describe Ai::ProviderExecutor do
  let(:provider_client) { instance_double('ProviderClient') }
  let(:backoff_policy) { Ai::BackoffPolicy.new(base_delay: 1.0, max_delay: 10.0, jitter: -> { 0.0 }) }
  let(:retry_policy) { Ai::RetryPolicy.new(max_retries: 2, backoff_policy: backoff_policy) }
  let(:input) { { filtered_content: 'sample receipt text' } }
  let(:payload) do
    {
      success: true,
      receipt_attributes: { store_name: 'Store' },
      receipt_items_attributes: [],
      meta: {
        metrics: {
          provider: 'openai',
          model: 'gpt-test',
          provider_status: '200',
          response_id: 'resp_123'
        }
      }
    }
  end
  let(:provider_result) do
    Ai::ProviderResult.new(
      provider: 'openai',
      model: 'gpt-test',
      payload: payload,
      metrics: payload.dig(:meta, :metrics),
      response_id: 'resp_123'
    )
  end

  subject(:executor) do
    described_class.new(
      provider_client: provider_client,
      provider_name: :openai,
      retry_policy: retry_policy
    )
  end

  describe '#call' do
    it '成功結果に共通metricsを付与して返す' do
      allow(provider_client).to receive(:call).with(input).and_return(provider_result)

      result = executor.call(input)

      aggregate_failures do
        expect(result).to be_a(Ai::ProviderResult)
        expect(result.payload).to eq(payload)
        expect(result.metrics).to include(
          provider: 'openai',
          model: 'gpt-test',
          provider_status: '200',
          response_id: 'resp_123',
          retry_count: 0,
          retry_after_used: false,
          total_retry_sleep_ms: 0,
          rate_limited: false
        )
        expect(result.metrics[:elapsed_ms]).to be_a(Integer)
        expect(result.payload.dig(:meta, :metrics)).to eq(result.metrics)
      end
    end

    it 'before_provider_callをprovider adapterへ渡す' do
      callback = instance_double(Proc)
      callback_executor = described_class.new(
        provider_client: provider_client,
        provider_name: :openai,
        retry_policy: retry_policy,
        before_provider_call: callback
      )
      allow(callback).to receive(:call)
      allow(provider_client).to receive(:call)
        .with(input, before_provider_call: callback)
        .and_return(provider_result)

      result = callback_executor.call(input)

      aggregate_failures do
        expect(result).to be_a(Ai::ProviderResult)
        expect(provider_client).to have_received(:call).with(input, before_provider_call: callback)
      end
    end

    it 'retry可能なProviderErrorの後に再試行して成功する' do
      call_count = 0
      allow(provider_client).to receive(:call).with(input) do
        call_count += 1
        raise Ai::Errors::ProviderError.new(message: 'server error', error_code: 'ai_api_error', provider: 'openai') if call_count == 1

        provider_result
      end
      allow(executor).to receive(:sleep)

      result = executor.call(input)

      aggregate_failures do
        expect(provider_client).to have_received(:call).with(input).twice
        expect(executor).to have_received(:sleep).with(1.0).once
        expect(result.metrics).to include(
          retry_count: 1,
          retry_after_used: false,
          total_retry_sleep_ms: 1000,
          rate_limited: false
        )
      end
    end

    it 'Retry-Afterがあればdelayとmetricsに反映する' do
      call_count = 0
      allow(provider_client).to receive(:call).with(input) do
        call_count += 1
        if call_count == 1
          raise Ai::Errors::RateLimitError.new(
            message: 'rate limited',
            error_code: 'ai_api_error',
            provider: 'openai',
            retry_after: 3.0
          )
        end

        provider_result
      end
      allow(executor).to receive(:sleep)

      result = executor.call(input)

      aggregate_failures do
        expect(executor).to have_received(:sleep).with(3.0).once
        expect(result.metrics).to include(
          retry_count: 1,
          retry_after_used: true,
          total_retry_sleep_ms: 3000,
          rate_limited: true
        )
      end
    end

    it '再試行上限を超えたerrorへmetricsを付与して送出する' do
      allow(provider_client).to receive(:call).with(input)
        .and_raise(Ai::Errors::ProviderError.new(message: 'server error', error_code: 'ai_api_error', provider: 'openai'))
      allow(executor).to receive(:sleep)

      expect do
        executor.call(input)
      end.to raise_error(Ai::Errors::ProviderError) { |error|
        aggregate_failures do
          expect(provider_client).to have_received(:call).with(input).exactly(3).times
          expect(executor).to have_received(:sleep).twice
          expect(error.metrics).to include(
            provider: 'openai',
            retry_count: 2,
            retry_after_used: false,
            total_retry_sleep_ms: 3000,
            rate_limited: false
          )
          expect(error.metrics[:elapsed_ms]).to be_a(Integer)
        end
      }
    end

    it 'retry不可のerrorは再試行しない' do
      allow(provider_client).to receive(:call).with(input)
        .and_raise(
          Ai::Errors::InvalidResponseError.new(
            message: 'invalid response',
            error_code: 'ai_invalid_response',
            provider: 'openai',
            retryable: false
          )
        )
      allow(executor).to receive(:sleep)

      expect do
        executor.call(input)
      end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
        aggregate_failures do
          expect(provider_client).to have_received(:call).with(input).once
          expect(executor).not_to have_received(:sleep)
          expect(error.metrics).to include(retry_count: 0)
        end
      }
    end

    it 'adapterがProviderResult以外を返した場合は契約違反として扱う' do
      allow(provider_client).to receive(:call).with(input).and_return(success: true)

      expect do
        executor.call(input)
      end.to raise_error(Ai::Errors::ProviderError) { |error|
        aggregate_failures do
          expect(error.error_code).to eq('ai_invalid_response')
          expect(error.category).to eq(:invalid_response)
          expect(error.retryable?).to eq(false)
          expect(error.fallbackable?).to eq(false)
        end
      }
    end

    it 'max elapsed到達後は次のprovider callを開始しない' do
      budget_executor = described_class.new(
        provider_client: provider_client,
        provider_name: :openai,
        retry_policy: retry_policy,
        deadline: 10.0
      )
      allow(budget_executor).to receive(:monotonic_now).and_return(11.0)
      allow(provider_client).to receive(:call)

      expect do
        budget_executor.call(input)
      end.to raise_error(Ai::Errors::TimeoutError) { |error|
        aggregate_failures do
          expect(error.error_code).to eq('ai_timeout')
          expect(error.retryable?).to eq(false)
          expect(error.fallbackable?).to eq(true)
          expect(provider_client).not_to have_received(:call)
        end
      }
    end

    it 'retry delayが残り時間以上ならsleepせずtimeoutへ倒す' do
      budget_executor = described_class.new(
        provider_client: provider_client,
        provider_name: :openai,
        retry_policy: retry_policy,
        deadline: 10.0
      )
      allow(budget_executor).to receive(:remaining_elapsed_seconds).and_return(0.5)
      allow(budget_executor).to receive(:sleep)
      allow(provider_client).to receive(:call).with(input).and_raise(
        Ai::Errors::ProviderError.new(
          message: 'server error',
          error_code: 'ai_api_error',
          provider: 'openai',
          retryable: true
        )
      )

      expect do
        budget_executor.call(input)
      end.to raise_error(Ai::Errors::TimeoutError) { |error|
        aggregate_failures do
          expect(error.error_code).to eq('ai_timeout')
          expect(provider_client).to have_received(:call).once
          expect(budget_executor).not_to have_received(:sleep)
        end
      }
    end

    it 'retryごとにprovider call前の利用量guardを再実行する' do
      callback_calls = 0
      quota_error = Usage::LimitExceeded.new(
        key: 'ai_jobs_per_day',
        limit: 1,
        used: 1,
        requested: 1
      )
      callback = lambda do
        callback_calls += 1
        raise quota_error if callback_calls == 2
      end
      guarded_executor = described_class.new(
        provider_client: provider_client,
        provider_name: :openai,
        retry_policy: retry_policy,
        before_provider_call: callback
      )
      allow(provider_client).to receive(:call)
        .with(input, before_provider_call: callback) do |_input, before_provider_call:|
          before_provider_call.call
          raise Ai::Errors::ProviderError.new(
            message: 'server error',
            error_code: 'ai_api_error',
            provider: 'openai',
            retryable: true
          )
        end
      allow(guarded_executor).to receive(:sleep)

      expect { guarded_executor.call(input) }.to raise_error(Usage::LimitExceeded)

      aggregate_failures do
        expect(callback_calls).to eq(2)
        expect(provider_client).to have_received(:call).twice
        expect(guarded_executor).to have_received(:sleep).with(1.0).once
      end
    end
  end
end
