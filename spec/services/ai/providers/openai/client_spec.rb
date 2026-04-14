require 'rails_helper'

RSpec.describe Ai::Providers::Openai::Client do
  let(:input) { { filtered_content: 'sample receipt text' } }
  let(:client) { described_class.new }
  let(:request_body) { { model: 'gpt-test', input: 'payload' } }
  let(:parsed_response) do
    {
      success: true,
      receipt_attributes: { 'store_name' => 'AI補正ストア' },
      receipt_items_attributes: [],
      meta: { provider: :openai, model: 'gpt-test' }
    }
  end

  describe '#call' do
    it 'RequestBuilder.build → post_request → ResponseParser.parse の順で呼び結果を返す' do
      allow(Ai::Providers::Openai::RequestBuilder).to receive(:build).with(input).and_return(request_body)
      allow(client).to receive(:post_request).with(request_body).and_return({ 'id' => 'resp_123' })
      allow(Ai::Providers::Openai::ResponseParser).to receive(:parse).with({ 'id' => 'resp_123' }).and_return(parsed_response)

      result = client.call(input)

      aggregate_failures do
        expect(Ai::Providers::Openai::RequestBuilder).to have_received(:build).with(input)
        expect(client).to have_received(:post_request).with(request_body)
        expect(Ai::Providers::Openai::ResponseParser).to have_received(:parse).with({ 'id' => 'resp_123' })
        expect(result).to eq(parsed_response)
      end
    end

    it '一時的な ProviderError の後に再試行して成功する' do
      allow(Ai::Providers::Openai::RequestBuilder).to receive(:build).with(input).and_return(request_body)
      call_count = 0
      allow(client).to receive(:post_request).with(request_body) do
        call_count += 1
        raise Ai::Errors::ProviderError.new(message: 'server error', error_code: 'ai_api_error') if call_count == 1

        { 'id' => 'resp_456' }
      end
      allow(Ai::Providers::Openai::ResponseParser).to receive(:parse).with({ 'id' => 'resp_456' }).and_return(parsed_response)
      allow(client).to receive(:sleep)

      result = client.call(input)

      aggregate_failures do
        expect(client).to have_received(:post_request).with(request_body).twice
        expect(client).to have_received(:sleep).once
        expect(result).to eq(parsed_response)
      end
    end

    it '再試行上限を超えた ProviderError はそのまま送出する' do
      allow(Ai::Providers::Openai::RequestBuilder).to receive(:build).with(input).and_return(request_body)
      allow(client).to receive(:post_request).with(request_body)
        .and_raise(Ai::Errors::ProviderError.new(message: 'server error', error_code: 'ai_api_error'))
      allow(client).to receive(:sleep)

      expect do
        client.call(input)
      end.to raise_error(Ai::Errors::ProviderError) { |error|
        aggregate_failures do
          expect(error.message).to eq('server error')
          expect(error.error_code).to eq('ai_api_error')
          expect(client).to have_received(:post_request).with(request_body).exactly(3).times
        end
      }
    end

    it 'AuthError は再試行せずそのまま送出する' do
      allow(Ai::Providers::Openai::RequestBuilder).to receive(:build).with(input).and_return(request_body)
      allow(client).to receive(:post_request).with(request_body)
        .and_raise(Ai::Errors::AuthError.new(message: 'auth failed', error_code: 'external_service_auth_error'))
      allow(client).to receive(:sleep)

      expect do
        client.call(input)
      end.to raise_error(Ai::Errors::AuthError) { |error|
        aggregate_failures do
          expect(error.message).to eq('auth failed')
          expect(error.error_code).to eq('external_service_auth_error')
          expect(client).to have_received(:post_request).with(request_body).once
          expect(client).not_to have_received(:sleep)
        end
      }
    end

    it 'RateLimitError は再試行後も失敗したらそのまま送出する' do
      allow(Ai::Providers::Openai::RequestBuilder).to receive(:build).with(input).and_return(request_body)
      allow(client).to receive(:post_request).with(request_body)
        .and_raise(Ai::Errors::RateLimitError.new(message: 'rate limited', error_code: 'external_service_unavailable'))
      allow(client).to receive(:sleep)

      expect do
        client.call(input)
      end.to raise_error(Ai::Errors::RateLimitError) { |error|
        aggregate_failures do
          expect(error.message).to eq('rate limited')
          expect(error.error_code).to eq('external_service_unavailable')
          expect(client).to have_received(:post_request).with(request_body).exactly(3).times
          expect(client).to have_received(:sleep).twice
        end
      }
    end

    it 'TimeoutError は再試行せずそのまま送出する' do
      allow(Ai::Providers::Openai::RequestBuilder).to receive(:build).with(input).and_return(request_body)
      allow(client).to receive(:post_request).with(request_body)
        .and_raise(Ai::Errors::TimeoutError.new(message: 'timeout', provider: :openai))
      allow(client).to receive(:sleep)

      expect do
        client.call(input)
      end.to raise_error(Ai::Errors::TimeoutError) { |error|
        aggregate_failures do
          expect(error.message).to eq('timeout')
          expect(error.error_code).to eq('ai_timeout')
          expect(client).to have_received(:post_request).with(request_body).once
          expect(client).not_to have_received(:sleep)
        end
      }
    end

    it 'InvalidResponseError は再試行せずそのまま送出する' do
      allow(Ai::Providers::Openai::RequestBuilder).to receive(:build).with(input).and_return(request_body)
      allow(client).to receive(:post_request).with(request_body)
        .and_raise(Ai::Errors::InvalidResponseError.new(message: 'invalid response', error_code: 'ai_invalid_response'))
      allow(client).to receive(:sleep)

      expect do
        client.call(input)
      end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
        aggregate_failures do
          expect(error.message).to eq('invalid response')
          expect(error.error_code).to eq('ai_invalid_response')
          expect(client).to have_received(:post_request).with(request_body).once
          expect(client).not_to have_received(:sleep)
        end
      }
    end
  end

  describe '#post_request' do
    let(:uri) { instance_double(URI::HTTPS, host: 'api.openai.com', port: 443, request_uri: '/v1/responses') }
    let(:http) { instance_double(Net::HTTP) }
    let(:request) { instance_double(Net::HTTP::Post) }
    let(:response) { instance_double(Net::HTTPSuccess, code: code, body: body) }
    let(:code) { '200' }
    let(:body) { '{"id":"resp_123"}' }

    before do
      allow(URI).to receive(:parse).and_return(uri)
      allow(Net::HTTP).to receive(:new).with('api.openai.com', 443).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(Net::HTTP::Post).to receive(:new).and_return(request)
      allow(request).to receive(:[]=)
      allow(request).to receive(:body=)
      allow(http).to receive(:request).with(request).and_return(response)
      allow(response).to receive(:is_a?) do |klass|
        klass == Net::HTTPSuccess && code.start_with?('2')
      end
    end

    it '200系なら parse_response_body の結果を返す' do
      allow(client).to receive(:parse_response_body).with(body).and_return({ 'id' => 'resp_123' })

      result = client.send(:post_request, request_body)

      aggregate_failures do
        expect(URI).to have_received(:parse)
        expect(Net::HTTP).to have_received(:new).with('api.openai.com', 443)
        expect(http).to have_received(:use_ssl=).with(true)
        expect(Net::HTTP::Post).to have_received(:new)
        expect(request).to have_received(:body=).with(request_body.to_json)
        expect(result).to eq({ 'id' => 'resp_123' })
      end
    end

    it '401 は AuthError を送出する' do
      allow(response).to receive(:code).and_return('401')
      allow(response).to receive(:body).and_return('{"error":"auth"}')

      expect do
        client.send(:post_request, request_body)
      end.to raise_error(Ai::Errors::AuthError) { |error|
        expect(error.message).to include('OpenAI API auth error: 401')
      }
    end

    it '403 は AuthError を送出する' do
      allow(response).to receive(:code).and_return('403')
      allow(response).to receive(:body).and_return('{"error":"forbidden"}')

      expect do
        client.send(:post_request, request_body)
      end.to raise_error(Ai::Errors::AuthError) { |error|
        expect(error.message).to include('OpenAI API auth error: 403')
      }
    end

    it '429 は RateLimitError を送出する' do
      allow(response).to receive(:code).and_return('429')
      allow(response).to receive(:body).and_return('{"error":"rate limited"}')

      expect do
        client.send(:post_request, request_body)
      end.to raise_error(Ai::Errors::RateLimitError) { |error|
        expect(error.message).to include('OpenAI API rate limit error: 429')
      }
    end

    it '500系は ProviderError を送出する' do
      allow(response).to receive(:code).and_return('500')
      allow(response).to receive(:body).and_return('{"error":"server"}')

      expect do
        client.send(:post_request, request_body)
      end.to raise_error(Ai::Errors::ProviderError) { |error|
        expect(error.message).to include('OpenAI API retryable server error: 500')
      }
    end

    it 'その他の非成功レスポンスは ProviderError を送出する' do
      allow(response).to receive(:code).and_return('422')
      allow(response).to receive(:body).and_return('{"error":"unprocessable"}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)

      expect do
        client.send(:post_request, request_body)
      end.to raise_error(Ai::Errors::ProviderError) { |error|
        expect(error.message).to include('OpenAI API error: 422')
      }
    end

    it 'Net::OpenTimeout はそのまま送出する' do
      allow(http).to receive(:request).with(request).and_raise(Net::OpenTimeout.new('timeout'))

      expect do
        client.send(:post_request, request_body)
      end.to raise_error(Net::OpenTimeout)
    end

    it 'Net::ReadTimeout はそのまま送出する' do
      allow(http).to receive(:request).with(request).and_raise(Net::ReadTimeout.new('timeout'))

      expect do
        client.send(:post_request, request_body)
      end.to raise_error(Net::ReadTimeout)
    end
  end

  describe '#parse_response_body' do
    it 'JSONをHashに変換する' do
      result = client.send(:parse_response_body, '{"id":"resp_123"}')

      expect(result).to eq({ 'id' => 'resp_123' })
    end

    it '不正JSONでは InvalidResponseError を送出する' do
      expect do
        client.send(:parse_response_body, 'not-json')
      end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
        expect(error.message).to eq('Invalid JSON response from OpenAI')
      }
    end
  end
end
