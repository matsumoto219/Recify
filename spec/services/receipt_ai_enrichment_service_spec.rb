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
    allow(ExternalServiceStatus).to receive(:mark_success!)
    allow(ExternalServiceStatus).to receive(:mark_failure!)
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
          expect(ExternalServiceStatus).to have_received(:mark_success!).with(:ai)
          expect(ExternalServiceStatus).not_to have_received(:mark_failure!)
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
          expect(ExternalServiceStatus).not_to have_received(:mark_success!)
          expect(ExternalServiceStatus).to have_received(:mark_failure!).with(:ai, error_code: 'ai_timeout')
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
          expect(ExternalServiceStatus).to have_received(:mark_success!).with(:ai)
          expect(ExternalServiceStatus).not_to have_received(:mark_failure!)
        end
      end
    end

    context '入力検証エラー' do
      it 'ocr_result が nil の場合は analysis_missing_keys を返す' do
        result = described_class.call(nil)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('analysis_missing_keys')
          expect(result[:needs_review]).to eq(true)
          expect(result[:receipt_attributes]).to eq({})
          expect(result[:receipt_items_attributes]).to eq([])
          expect(ExternalServiceStatus).not_to have_received(:mark_success!)
          expect(ExternalServiceStatus).to have_received(:mark_failure!).with(:ai, error_code: 'analysis_missing_keys')
        end
      end

      it 'success が false の場合は analysis_missing_keys を返す' do
        invalid_ocr_result = valid_ocr_result.merge(success: false)

        result = described_class.call(invalid_ocr_result)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('analysis_missing_keys')
          expect(ExternalServiceStatus).not_to have_received(:mark_success!)
          expect(ExternalServiceStatus).to have_received(:mark_failure!).with(:ai, error_code: 'analysis_missing_keys')
        end
      end

      it 'lines が配列でない場合は analysis_missing_keys を返す' do
        invalid_ocr_result = valid_ocr_result.merge(lines: nil)

        result = described_class.call(invalid_ocr_result)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('analysis_missing_keys')
          expect(ExternalServiceStatus).not_to have_received(:mark_success!)
          expect(ExternalServiceStatus).to have_received(:mark_failure!).with(:ai, error_code: 'analysis_missing_keys')
        end
      end

      it 'candidates が Hash でない場合は analysis_missing_keys を返す' do
        invalid_ocr_result = valid_ocr_result.merge(candidates: nil)

        result = described_class.call(invalid_ocr_result)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('analysis_missing_keys')
          expect(ExternalServiceStatus).not_to have_received(:mark_success!)
          expect(ExternalServiceStatus).to have_received(:mark_failure!).with(:ai, error_code: 'analysis_missing_keys')
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
          expect(ExternalServiceStatus).not_to have_received(:mark_success!)
          expect(ExternalServiceStatus).to have_received(:mark_failure!).with(:ai, error_code: 'ai_api_error')
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
          expect(ExternalServiceStatus).not_to have_received(:mark_success!)
          expect(ExternalServiceStatus).to have_received(:mark_failure!).with(:ai, error_code: 'ai_api_error')
        end
      end
    end
  end
end
