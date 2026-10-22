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
          'status' => 'completed',
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
          meta: {
            provider: 'openai',
            response_id: 'resp_456',
            model: 'gpt-test',
            metrics: { response_id: 'resp_456', model: 'gpt-test', response_status: 'completed' }
          }
        )
      end
    end

    context 'Responses APIのenvelopeの場合' do
      let(:payload) do
        {
          'is_receipt' => true,
          'document_type' => 'receipt',
          'rejection_reason' => nil,
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'receipt_adjustments' => [],
          'needs_review' => false,
          'review_reasons' => []
        }
      end
      let(:response) do
        {
          'object' => 'response',
          'model' => 'gpt-returned',
          'status' => 'completed',
          'usage' => {
            'input_tokens' => 10,
            'input_tokens_details' => { 'cached_tokens' => 4 },
            'output_tokens' => 20,
            'output_tokens_details' => { 'reasoning_tokens' => 8 },
            'total_tokens' => 30
          },
          Ai::ProviderMetrics::METADATA_KEY => {
            requested_model: 'gpt-requested',
            reasoning_effort: 'high',
            provider_status: '200',
            raw_response: 'private response'
          },
          'output' => [
            {
              'type' => 'message',
              'content' => [ { 'type' => 'output_text', 'text' => payload.to_json } ]
            }
          ]
        }
      end
      let(:safe_metrics) do
        {
          model: 'gpt-returned',
          requested_model: 'gpt-requested',
          reasoning_effort: 'high',
          provider_status: '200',
          response_status: 'completed',
          token_usage: { input_tokens: 10, cached_input_tokens: 4, output_tokens: 20, reasoning_tokens: 8, total_tokens: 30 }
        }
      end

      it 'completedのJSONだけを採用しsafe metricsを保持する' do
        response['output'].unshift('type' => 'reasoning', 'summary' => [ { 'text' => 'private reasoning' } ])

        result = described_class.parse(response, provider_response: true)

        aggregate_failures do
          expect(result[:success]).to be(true)
          expect(result.dig(:meta, :metrics)).to eq(safe_metrics)
          expect(result.to_s).not_to include('private reasoning', 'private response')
        end
      end

      %w[incomplete failed cancelled queued in_progress unknown].each do |status|
        it "#{status} の有効JSONも採用せずretry不可にする" do
          response['status'] = status
          response['incomplete_details'] = { 'reason' => 'max_output_tokens' } if status == 'incomplete'
          allow(Ai::ResponseParser).to receive(:parse)

          expect do
            described_class.parse(response, provider_response: true)
          end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
            aggregate_failures do
              expect(error.error_code).to eq('ai_invalid_response')
              expect(error.retryable?).to be(false)
              expect(error.fallbackable?).to be(false)
              expect(error.metrics[:token_usage]).to eq(safe_metrics[:token_usage])
              expect(error.metrics[:response_status]).to eq(status == 'unknown' ? nil : status)
              expect(error.metrics[:incomplete_reason]).to eq(status == 'incomplete' ? 'max_output_tokens' : nil)
              expect(error.metrics.dig(:diagnostic, :local_issue)).to eq(status == 'incomplete' ? 'incomplete' : 'invalid_response')
            end
          }
          expect(Ai::ResponseParser).not_to have_received(:parse)
        end
      end

      it 'API envelopeのstatus欠損を内部helper扱いせず拒否する' do
        response.delete('status')

        expect { described_class.parse(response) }.to raise_error(Ai::Errors::InvalidResponseError)
      end

      it 'failedの構造化された原因だけを保持し応答本文は残さない' do
        response['status'] = 'failed'
        response['error'] = {
          'code' => 'server_error',
          'message' => 'The service could not process this response.',
          'param' => 'input',
          'debug' => 'private debug'
        }

        expect do
          described_class.parse(response, provider_response: true)
        end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
          aggregate_failures do
            expect(error.metrics[:diagnostic]).to include(
              nodes: [
                {
                  path: 'error',
                  code: 'server_error',
                  message_safe: 'The service could not process this response.',
                  param: 'input'
                }
              ]
            )
            expect(error.provider_error_code).to eq('server_error')
            expect(error.phase).to eq('ai_response')
            expect(error.metrics.to_s).not_to include('private debug', 'private response', payload.to_json)
            expect(error).not_to be_retryable
            expect(error).not_to be_fallbackable
          end
        }
      end

      it '未登録の安全なincomplete reasonも診断に保持し分類やretryを変えない' do
        response['status'] = 'incomplete'
        response['error'] = nil
        response['incomplete_details'] = { 'reason' => 'future_incomplete_reason', 'debug' => 'private details' }
        expected_nodes = [ { path: 'incomplete_details', reason: 'future_incomplete_reason' } ]
        expected_omissions = [ { path: 'incomplete_details', reason: 'unsupported_fields' } ]

        expect do
          described_class.parse(response, provider_response: true)
        end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
          aggregate_failures do
            expect(error.error_code).to eq('ai_invalid_response')
            expect(error.metrics[:incomplete_reason]).to be_nil
            expect(error.metrics.dig(:diagnostic, :local_issue)).to eq('incomplete')
            expect(error.metrics.dig(:diagnostic, :nodes)).to eq(expected_nodes)
            expect(error.metrics.dig(:diagnostic, :omissions)).to eq(expected_omissions)
            expect(error.metrics.to_s).not_to include('private details', payload.to_json)
            expect(error).not_to be_retryable
            expect(error).not_to be_fallbackable
          end
        }
      end

      it 'incomplete reason内の機密情報を保存せず除外した箇所を記録する' do
        response['status'] = 'incomplete'
        response['incomplete_details'] = { 'reason' => 'Bearer private-credential' }

        expect do
          described_class.parse(response, provider_response: true)
        end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
          aggregate_failures do
            expect(error.metrics[:incomplete_reason]).to be_nil
            expect(error.metrics.dig(:diagnostic, :omissions)).to include(path: 'incomplete_details.reason', reason: 'redacted')
            expect(error.metrics.to_s).not_to include('private-credential')
          end
        }
      end

      it 'HTTP応答のoutput_text helper形でもstatus欠損を拒否する' do
        response = { 'output_text' => payload.to_json }

        expect { described_class.parse(response, provider_response: true) }.to raise_error(Ai::Errors::InvalidResponseError)
      end

      it 'HTTP応答の正規化済みHash形でもstatus欠損を拒否する' do
        expect { described_class.parse(payload, provider_response: true) }.to raise_error(Ai::Errors::InvalidResponseError)
      end

      it 'HTTP応答の正規化済みHashにcompletedがあってもhelperとして採用しない' do
        response = payload.merge('status' => 'completed')

        expect { described_class.parse(response, provider_response: true) }.to raise_error(Ai::Errors::InvalidResponseError)
      end

      it 'completedのAPI envelopeに出力がなければ直下のstoreを採用しない' do
        response.merge!(payload)
        response['output'] = []

        expect do
          described_class.parse(response)
        end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
          aggregate_failures do
            expect(error.error_code).to eq('ai_invalid_response')
            expect(error.retryable?).to be(false)
            expect(error.fallbackable?).to be(false)
            expect(error.metrics).to include(safe_metrics)
            expect(error.metrics.dig(:diagnostic, :local_issue)).to eq('invalid_response')
          end
        }
      end

      it 'JSON文字列とrefusalが混在しても採用しない' do
        response['output_text'] = payload.to_json
        response['output'].first['content'] << { 'type' => 'refusal', 'refusal' => 'private refusal' }

        expect do
          described_class.parse(response, provider_response: true)
        end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
          aggregate_failures do
            expect(error.error_code).to eq('ai_invalid_response')
            expect(error.retryable?).to be(false)
            expect(error.fallbackable?).to be(false)
            expect(error.metrics).to include(safe_metrics)
            expect(error.metrics.dig(:diagnostic, :local_issue)).to eq('refusal')
            expect(error.metrics.to_s).not_to include('private refusal', 'private response')
          end
        }
      end

      it 'reasoning項目のtextをJSON payloadとして採用しない' do
        response['output'] = [ { 'type' => 'reasoning', 'content' => [ { 'type' => 'reasoning_text', 'text' => payload.to_json } ] } ]

        expect { described_class.parse(response, provider_response: true) }.to raise_error(Ai::Errors::InvalidResponseError)
      end

      it '不正JSONでもusageと要求設定を失わない' do
        response['output'].first['content'].first['text'] = '{invalid-json}'

        expect do
          described_class.parse(response, provider_response: true)
        end.to raise_error(Ai::Errors::InvalidResponseError) { |error|
          aggregate_failures do
            expect(error.metrics).to include(safe_metrics)
            expect(error.metrics.dig(:diagnostic, :local_issue)).to eq('invalid_json')
          end
        }
      end

      it 'domain parse errorの分類とretry不可をsafe metrics付きで維持する' do
        response['output'].first['content'].first['text'] = payload.except('items').to_json

        expect do
          described_class.parse(response, provider_response: true)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.class).to eq(Ai::Errors::ProviderError)
            expect(error.error_code).to eq('analysis_missing_keys')
            expect(error.retryable?).to be(false)
            expect(error.fallbackable?).to be(false)
            expect(error.metrics).to include(safe_metrics)
          end
        }
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
