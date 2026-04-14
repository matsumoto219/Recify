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
        allow(primary_client).to receive(:call).with(input).and_return(primary_result)
        allow(fallback_client).to receive(:call)

        result = client.call(input)

        aggregate_failures do
          expect(result).to eq(primary_result)
          expect(primary_client).to have_received(:call).with(input)
          expect(fallback_client).not_to have_received(:call)
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
        allow(fallback_client).to receive(:call).with(input).and_return(fallback_result)

        result = client.call(input)

        aggregate_failures do
          expect(primary_client).to have_received(:call).with(input)
          expect(fallback_client).to have_received(:call).with(input)
          expect(result[:success]).to eq(true)
          expect(result.dig(:meta, :fallback_used)).to eq(true)
          expect(result.dig(:meta, :provider)).to eq('fallback_ai')
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
        allow(fallback_client).to receive(:call).with(input).and_return(fallback_result)

        result = client.call(input)

        aggregate_failures do
          expect(primary_client).to have_received(:call).with(input)
          expect(fallback_client).to have_received(:call).with(input)
          expect(result[:success]).to eq(true)
          expect(result.dig(:meta, :fallback_used)).to eq(true)
        end
      end
    end

    context 'primary が fallback対象外のエラーを返す場合' do
      it 'AuthError 時は fallback を試し、成功すれば fallback 結果を返す' do
        fallback_result = {
          success: true,
          receipt_attributes: { store_name: 'Fallback Store' },
          receipt_items_attributes: []
        }

        allow(primary_client).to receive(:call).with(input).and_raise(Ai::Errors::AuthError.new(message: 'auth failed'))
        allow(fallback_client).to receive(:call).with(input).and_return(fallback_result)

        result = client.call(input)

        aggregate_failures do
          expect(result[:success]).to eq(true)
          expect(result.dig(:meta, :fallback_used)).to eq(true)
          expect(fallback_client).to have_received(:call).with(input)
        end
      end

      it 'InvalidResponseError 時は fallback を試し、成功すれば fallback 結果を返す' do
        fallback_result = {
          success: true,
          receipt_attributes: { store_name: 'Fallback Store' },
          receipt_items_attributes: []
        }

        allow(primary_client).to receive(:call).with(input).and_raise(Ai::Errors::InvalidResponseError.new(message: 'invalid response'))
        allow(fallback_client).to receive(:call).with(input).and_return(fallback_result)

        result = client.call(input)

        aggregate_failures do
          expect(result[:success]).to eq(true)
          expect(result.dig(:meta, :fallback_used)).to eq(true)
          expect(fallback_client).to have_received(:call).with(input)
        end
      end
    end

    context 'fallback provider が未設定の場合' do
      let(:fallback_provider) { nil }

      before do
        allow(Ai::ProviderRegistry).to receive(:fetch).with(nil).and_return(nil)
      end

      it 'primary 失敗時に error result を返す' do
        error = Ai::Errors::ProviderError.new(message: 'primary failed', error_code: 'ai_primary_failed')
        allow(primary_client).to receive(:call).with(input).and_raise(error)

        result = client.call(input)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ai_primary_failed')
          expect(result.dig(:meta, :primary_error_code)).to eq('ai_primary_failed')
          expect(result.dig(:meta, :fallback_used)).to eq(false)
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
        allow(primary_client).to receive(:call).with(input).and_raise(Ai::Errors::TimeoutError.new(message: 'timeout'))

        result = client.call(input)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ai_primary_failed')
          expect(result.dig(:meta, :primary_error_code)).to eq('ai_primary_failed')
          expect(result.dig(:meta, :fallback_used)).to eq(false)
        end
      end
    end
  end
end
