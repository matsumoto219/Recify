require 'rails_helper'

RSpec.describe Ai::Providers::Openai::ResponseParser do
  let(:provider) { 'openai' }

  describe '.parse' do
    context 'output_text 直下にJSON文字列がある場合' do
      let(:response) do
        {
          'id' => 'resp_123',
          'model' => 'gpt-test',
          'output_text' => <<~JSON
            {
              "store": {
                "store_name": "AI補正ストア",
                "store_address": "東京都渋谷区1-2-3",
                "store_phone_number": "03-1234-5678"
              },
              "purchase": {
                "purchased_at_text": "2026-04-15 12:34"
              },
              "payment": {
                "payment_method": "credit_card"
              },
              "items": [
                {
                  "index": 0,
                  "suggested_name": "ブレンドコーヒー",
                  "category": "drink",
                  "needs_review": false
                }
              ],
              "needs_review": false,
              "review_reasons": []
            }
          JSON
        }
      end

      let(:parsed_result) do
        {
          success: true,
          receipt_attributes: { 'store_name' => 'AI補正ストア' },
          receipt_items_attributes: [],
          meta: { provider: 'openai' }
        }
      end

      it 'JSON payload をパースして Ai::ResponseParser に渡す' do
        expected_payload = {
          'store' => {
            'store_name' => 'AI補正ストア',
            'store_address' => '東京都渋谷区1-2-3',
            'store_phone_number' => '03-1234-5678'
          },
          'purchase' => {
            'purchased_at_text' => '2026-04-15 12:34'
          },
          'payment' => {
            'payment_method' => 'credit_card'
          },
          'items' => [
            {
              'index' => 0,
              'suggested_name' => 'ブレンドコーヒー',
              'category' => 'drink',
              'needs_review' => false
            }
          ],
          'needs_review' => false,
          'review_reasons' => []
        }

        allow(Ai::ResponseParser).to receive(:parse)
          .with(
            expected_payload,
            provider: provider,
            meta: { provider: 'openai', response_id: 'resp_123', model: 'gpt-test' }
          )
          .and_return(parsed_result)

        result = described_class.parse(response)

        aggregate_failures do
          expect(Ai::ResponseParser).to have_received(:parse)
          expect(result).to eq(parsed_result)
        end
      end
    end

    context 'Recify内部のAI metricsがある場合' do
      let(:response) do
        {
          'id' => 'resp_metrics',
          'model' => 'gpt-test',
          'usage' => {
            'input_tokens' => 10,
            'output_tokens' => 20,
            'total_tokens' => 30
          },
          Ai::ProviderMetrics::METADATA_KEY => {
            provider: 'openai',
            retry_count: 1,
            retry_after_used: true,
            total_retry_sleep_ms: 3000,
            rate_limited: true,
            provider_status: '200'
          },
          'output_text' => '{"store":{},"purchase":{},"payment":{},"items":[],"needs_review":false,"review_reasons":[]}'
        }
      end

      it 'AI metricsをmetaへ渡す' do
        allow(Ai::ResponseParser).to receive(:parse).and_return(success: true)

        described_class.parse(response)

        expect(Ai::ResponseParser).to have_received(:parse).with(
          {
            'store' => {},
            'purchase' => {},
            'payment' => {},
            'items' => [],
            'needs_review' => false,
            'review_reasons' => []
          },
          provider: provider,
          meta: {
            provider: 'openai',
            response_id: 'resp_metrics',
            model: 'gpt-test',
            metrics: {
              provider: 'openai',
              model: 'gpt-test',
              retry_count: 1,
              retry_after_used: true,
              total_retry_sleep_ms: 3000,
              rate_limited: true,
              provider_status: '200',
              token_usage: {
                input_tokens: 10,
                output_tokens: 20,
                total_tokens: 30
              },
              response_id: 'resp_metrics'
            }
          }
        )
      end
    end

    context 'output[].content[].text にJSON文字列がある場合' do
      let(:response) do
        {
          'id' => 'resp_456',
          'model' => 'gpt-test',
          'output' => [
            {
              'content' => [
                {
                  'type' => 'output_text',
                  'text' => <<~JSON
                    {
                      "store": {},
                      "purchase": {},
                      "payment": {},
                      "items": [],
                      "needs_review": true,
                      "review_reasons": ["item_name_uncertain"]
                    }
                  JSON
                }
              ]
            }
          ]
        }
      end

      it 'nested output からJSON payload を抽出して渡す' do
        expected_payload = {
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => true,
          'review_reasons' => [ 'item_name_uncertain' ]
        }

        allow(Ai::ResponseParser).to receive(:parse).and_return(success: true)

        described_class.parse(response)

        expect(Ai::ResponseParser).to have_received(:parse).with(
          expected_payload,
          provider: provider,
          meta: { provider: 'openai', response_id: 'resp_456', model: 'gpt-test' }
        )
      end
    end

    context 'response 自体が store を持つHashの場合' do
      let(:response) do
        {
          'store' => {
            'store_name' => 'Hash Store'
          },
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => false,
          'review_reasons' => []
        }
      end

      it 'そのまま Ai::ResponseParser に渡す' do
        allow(Ai::ResponseParser).to receive(:parse).and_return(success: true)

        described_class.parse(response)

        expect(Ai::ResponseParser).to have_received(:parse).with(
          response,
          provider: provider,
          meta: { provider: 'openai' }
        )
      end
    end

    context 'response がJSON文字列の場合' do
      let(:response) do
        {
          'id' => 'resp_789',
          'model' => 'gpt-test',
          'output_text' => '{"store":{},"purchase":{},"payment":{},"items":[],"needs_review":false,"review_reasons":[]}'
        }.to_json
      end

      it '文字列をHashに変換してから処理する' do
        expected_payload = {
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => false,
          'review_reasons' => []
        }

        allow(Ai::ResponseParser).to receive(:parse).and_return(success: true)

        described_class.parse(response)

        expect(Ai::ResponseParser).to have_received(:parse).with(
          expected_payload,
          provider: provider,
          meta: { provider: 'openai', response_id: 'resp_789', model: 'gpt-test' }
        )
      end
    end

    context 'output_text のJSONが壊れている場合' do
      let(:response) do
        {
          'id' => 'resp_bad',
          'model' => 'gpt-test',
          'output_text' => '{invalid-json}'
        }
      end

      it 'InvalidResponseError を送出する' do
        expect do
          described_class.parse(response)
        end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
          aggregate_failures do
            expect(error.message).to eq('Failed to parse OpenAI JSON payload')
            expect(error.provider).to eq(provider)
          end
        }
      end
    end

    context 'JSON payload が存在しない場合' do
      let(:response) do
        {
          'id' => 'resp_empty',
          'model' => 'gpt-test'
        }
      end

      it 'InvalidResponseError を送出する' do
        expect do
          described_class.parse(response)
        end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
          aggregate_failures do
            expect(error.message).to eq('OpenAI response did not contain a JSON payload')
            expect(error.provider).to eq(provider)
          end
        }
      end
    end

    context 'response がHashでもStringでもない場合' do
      let(:response) { 123 }

      it 'InvalidResponseError を送出する' do
        expect do
          described_class.parse(response)
        end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
          aggregate_failures do
            expect(error.message).to eq('OpenAI response must be a Hash or JSON string')
            expect(error.provider).to eq(provider)
          end
        }
      end
    end

    context 'Ai::ResponseParser が ProviderError を送出する場合' do
      let(:response) do
        {
          'id' => 'resp_provider',
          'model' => 'gpt-test',
          'output_text' => '{"store":{},"purchase":{},"payment":{},"items":[],"needs_review":false,"review_reasons":[]}'
        }
      end

      it 'そのまま再送出する' do
        allow(Ai::ResponseParser).to receive(:parse)
          .and_raise(Ai::Errors::ProviderError.new(message: 'provider invalid', error_code: 'ai_invalid_response', provider: provider))

        expect do
          described_class.parse(response)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.message).to eq('provider invalid')
            expect(error.error_code).to eq('ai_invalid_response')
            expect(error.provider).to eq(provider)
          end
        }
      end
    end

    context '予期しない例外が発生した場合' do
      let(:response) do
        {
          'id' => 'resp_unexpected',
          'model' => 'gpt-test',
          'output_text' => '{"store":{},"purchase":{},"payment":{},"items":[],"needs_review":false,"review_reasons":[]}'
        }
      end

      it 'InvalidResponseError でラップして送出する' do
        allow(Ai::ResponseParser).to receive(:parse).and_raise(StandardError.new('boom'))

        expect do
          described_class.parse(response)
        end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
          aggregate_failures do
            expect(error.message).to eq('Failed to parse OpenAI response')
            expect(error.provider).to eq(provider)
          end
        }
      end
    end
  end
end
