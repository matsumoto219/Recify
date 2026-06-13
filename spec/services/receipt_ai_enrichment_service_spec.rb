require 'rails_helper'

RSpec.describe ReceiptAiEnrichmentService do
  let(:client) { instance_double(Ai::Client) }

  let(:valid_ocr_result) do
    {
      success: true,
      raw_text: 'サンプルコンビニ コーヒー 180円',
      lines: [
        'サンプルコンビニ',
        'コーヒー 180円'
      ],
      candidates: {
        store_name: 'サンプルコンビニ',
        payment_method_text: 'クレジット'
      },
      meta: {
        provider: 'azure_document_intelligence',
        model_id: 'prebuilt-receipt'
      }
    }
  end

  let(:successful_ai_result) do
    {
      success: true,
      needs_review: false,
      receipt_attributes: {
        store_name: 'AI補正ストア',
        payment_method: 'credit_card'
      },
      receipt_items_attributes: [
        {
          index: 0,
          suggested_name: 'ブレンドコーヒー',
          category: 'drink',
          needs_review: false
        }
      ]
    }
  end

  before do
    allow(Ai::Client).to receive(:new).and_return(client)
    allow(ExternalServices).to receive(:mark_success!)
    allow(ExternalServices).to receive(:mark_failure!)
  end

  describe '.call' do
    context '正常系' do
      it 'AI成功時は結果をそのまま返し success を記録する' do
        allow(Ai::PromptBuilder).to receive(:build).with(valid_ocr_result, ai_name_completion_enabled: false).and_return({ filtered_content: 'test' })
        allow(client).to receive(:call).with({ filtered_content: 'test' }).and_return(successful_ai_result)

        result = described_class.call(valid_ocr_result)

        aggregate_failures do
          expect(Ai::PromptBuilder).to have_received(:build).with(valid_ocr_result, ai_name_completion_enabled: false)
          expect(client).to have_received(:call).with({ filtered_content: 'test' })
          expect(result).to eq(successful_ai_result)
          expect(ExternalServices).to have_received(:mark_success!).with(:ai)
          expect(ExternalServices).not_to have_received(:mark_failure!)
        end
      end

      it 'before_provider_callをAI client呼び出し直前に実行する' do
        events = []
        before_provider_call = -> { events << :before_provider_call }
        allow(Ai::PromptBuilder).to receive(:build).with(valid_ocr_result, ai_name_completion_enabled: false).and_return({ filtered_content: 'test' })
        allow(client).to receive(:call).with({ filtered_content: 'test' }, before_provider_call: before_provider_call) do |_input, before_provider_call:|
          before_provider_call.call
          events << :client_call
          successful_ai_result
        end

        result = described_class.call(valid_ocr_result, before_provider_call: before_provider_call)

        aggregate_failures do
          expect(result).to eq(successful_ai_result)
          expect(events).to eq(%i[before_provider_call client_call])
        end
      end

      it 'capture_inputにPromptBuilder結果を渡し戻り値互換を維持する' do
        input = { filtered_content: 'test', meta: { item_count: 1 } }
        capture_input = instance_double(Proc)
        allow(Ai::PromptBuilder).to receive(:build).with(valid_ocr_result, ai_name_completion_enabled: false).and_return(input)
        allow(capture_input).to receive(:call).with(input)
        allow(client).to receive(:call).with(input).and_return(successful_ai_result)

        result = described_class.call(valid_ocr_result, capture_input: capture_input)

        aggregate_failures do
          expect(capture_input).to have_received(:call).with(input)
          expect(client).to have_received(:call).with(input)
          expect(result).to eq(successful_ai_result)
        end
      end

      it 'capture_input例外は握りつぶさずAI本処理を実行しない' do
        input = { filtered_content: 'test' }
        capture_error = StandardError.new('capture failed')
        capture_input = ->(_payload) { raise capture_error }
        allow(Ai::PromptBuilder).to receive(:build).with(valid_ocr_result, ai_name_completion_enabled: false).and_return(input)
        allow(client).to receive(:call)

        expect do
          described_class.call(valid_ocr_result, capture_input: capture_input)
        end.to raise_error(ReceiptAiEnrichmentService::InputCaptureError, 'capture failed')

        aggregate_failures do
          expect(client).not_to have_received(:call)
          expect(ExternalServices).not_to have_received(:mark_success!)
          expect(ExternalServices).not_to have_received(:mark_failure!)
        end
      end

      it 'AI失敗結果をそのまま返し failure を記録する' do
        failed_result = {
          success: false,
          error_code: 'ai_timeout',
          needs_review: true,
          receipt_attributes: {},
          receipt_items_attributes: []
        }

        allow(Ai::PromptBuilder).to receive(:build).with(valid_ocr_result, ai_name_completion_enabled: false).and_return({ filtered_content: 'test' })
        allow(client).to receive(:call).with({ filtered_content: 'test' }).and_return(failed_result)

        result = described_class.call(valid_ocr_result)

        aggregate_failures do
          expect(result).to eq(failed_result)
          expect(ExternalServices).not_to have_received(:mark_success!)
          expect(ExternalServices).to have_received(:mark_failure!).with(:ai, error_code: 'ai_timeout')
        end
      end

      it 'AI失敗結果のsafe provider detailをfailureへ渡す' do
        detail = {
          service: 'ai',
          provider: 'openai',
          phase: 'ai_request',
          http_status: 429,
          provider_error_code: 'rate_limit_exceeded',
          retry_after: 15,
          rate_limited: true
        }
        failed_result = {
          success: false,
          error_code: 'ai_rate_limited',
          needs_review: true,
          receipt_attributes: {},
          receipt_items_attributes: [],
          meta: {
            final_error_detail: detail
          }
        }

        allow(Ai::PromptBuilder).to receive(:build).with(valid_ocr_result, ai_name_completion_enabled: false).and_return({ filtered_content: 'test' })
        allow(client).to receive(:call).with({ filtered_content: 'test' }).and_return(failed_result)

        result = described_class.call(valid_ocr_result)

        aggregate_failures do
          expect(result).to eq(failed_result)
          expect(ExternalServices).not_to have_received(:mark_success!)
          expect(ExternalServices).to have_received(:mark_failure!).with(:ai, error_code: 'ai_rate_limited', detail: detail)
        end
      end

      it 'AI provider errorを分類したままsafe detail付きの失敗結果にする' do
        error = Ai::Errors::AuthError.new(
          message: 'OPENAI_API_KEY is not set',
          error_code: 'ai_auth_error',
          provider: 'openai',
          provider_status: 'configuration',
          provider_error_code: 'api_key_missing',
          provider_error_type: 'configuration',
          provider_message: 'OpenAI API key is missing',
          auth_error: true,
          phase: 'configuration'
        )
        allow(Ai::PromptBuilder).to receive(:build).with(valid_ocr_result, ai_name_completion_enabled: false).and_return({ filtered_content: 'test' })
        allow(client).to receive(:call).with({ filtered_content: 'test' }).and_raise(error)

        result = described_class.call(valid_ocr_result)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ai_auth_error')
          expect(result.dig(:meta, :final_error_detail)).to include(
          service: 'ai',
          provider: 'openai',
          phase: 'configuration',
          provider_error_code: 'api_key_missing',
          provider_error_type: 'configuration',
          provider_message_safe: 'OpenAI API key is missing',
            auth_error: true
          )
          expect(ExternalServices).to have_received(:mark_failure!).with(
            :ai,
            error_code: 'ai_auth_error',
            detail: hash_including(
              provider_error_code: 'api_key_missing',
              auth_error: true
            )
          )
        end
      end

      it 'AIがnot receiptと正常判定した場合はfailureを記録しない' do
        not_receipt_result = {
          success: false,
          error_code: 'ai_not_receipt',
          needs_review: false,
          receipt_attributes: {},
          receipt_items_attributes: [],
          meta: {
            document_type: 'development_note',
            rejection_reason: 'memo'
          }
        }

        allow(Ai::PromptBuilder).to receive(:build).with(valid_ocr_result, ai_name_completion_enabled: false).and_return({ filtered_content: 'test' })
        allow(client).to receive(:call).with({ filtered_content: 'test' }).and_return(not_receipt_result)

        result = described_class.call(valid_ocr_result)

        aggregate_failures do
          expect(result).to eq(not_receipt_result)
          expect(ExternalServices).to have_received(:mark_success!).with(:ai)
          expect(ExternalServices).not_to have_received(:mark_failure!)
        end
      end
    end

    context '入力検証エラー' do
      it 'ocr_result が nil の場合は analysis_missing_keys を返す' do
        before_provider_call = instance_double(Proc)
        allow(before_provider_call).to receive(:call)

        result = described_class.call(nil, before_provider_call: before_provider_call)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('analysis_missing_keys')
          expect(result[:needs_review]).to eq(true)
          expect(result[:receipt_attributes]).to eq({})
          expect(result[:receipt_items_attributes]).to eq([])
          expect(before_provider_call).not_to have_received(:call)
          expect(ExternalServices).not_to have_received(:mark_success!)
          expect(ExternalServices).to have_received(:mark_failure!).with(:ai, error_code: 'analysis_missing_keys')
        end
      end

      it 'success が false の場合は analysis_missing_keys を返す' do
        invalid_ocr_result = valid_ocr_result.merge(success: false)

        result = described_class.call(invalid_ocr_result)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('analysis_missing_keys')
          expect(ExternalServices).not_to have_received(:mark_success!)
          expect(ExternalServices).to have_received(:mark_failure!).with(:ai, error_code: 'analysis_missing_keys')
        end
      end

      it 'lines が配列でない場合は analysis_missing_keys を返す' do
        invalid_ocr_result = valid_ocr_result.merge(lines: nil)

        result = described_class.call(invalid_ocr_result)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('analysis_missing_keys')
          expect(ExternalServices).not_to have_received(:mark_success!)
          expect(ExternalServices).to have_received(:mark_failure!).with(:ai, error_code: 'analysis_missing_keys')
        end
      end

      it 'candidates が Hash でない場合は analysis_missing_keys を返す' do
        invalid_ocr_result = valid_ocr_result.merge(candidates: nil)

        result = described_class.call(invalid_ocr_result)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('analysis_missing_keys')
          expect(ExternalServices).not_to have_received(:mark_success!)
          expect(ExternalServices).to have_received(:mark_failure!).with(:ai, error_code: 'analysis_missing_keys')
        end
      end
    end

    context '想定外エラー' do
      it 'PromptBuilder が例外を出した場合は ai_api_error を返す' do
        allow(Ai::PromptBuilder).to receive(:build).and_raise(StandardError.new('boom'))

        result = described_class.call(valid_ocr_result)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ai_api_error')
          expect(result[:needs_review]).to eq(true)
          expect(result[:receipt_attributes]).to eq({})
          expect(result[:receipt_items_attributes]).to eq([])
          expect(ExternalServices).not_to have_received(:mark_success!)
          expect(ExternalServices).to have_received(:mark_failure!).with(:ai, error_code: 'ai_api_error')
        end
      end

      it 'Ai::Client が例外を出した場合は ai_api_error を返す' do
        allow(Ai::PromptBuilder).to receive(:build).with(valid_ocr_result, ai_name_completion_enabled: false).and_return({ filtered_content: 'test' })
        allow(client).to receive(:call).with({ filtered_content: 'test' }).and_raise(StandardError.new('boom'))

        result = described_class.call(valid_ocr_result)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ai_api_error')
          expect(result[:needs_review]).to eq(true)
          expect(result[:receipt_attributes]).to eq({})
          expect(result[:receipt_items_attributes]).to eq([])
          expect(ExternalServices).not_to have_received(:mark_success!)
          expect(ExternalServices).to have_received(:mark_failure!).with(:ai, error_code: 'ai_api_error')
        end
      end
    end
  end
end
