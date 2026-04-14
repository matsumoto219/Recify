require 'rails_helper'

RSpec.describe ReceiptOcrService do
  describe '.call' do
    let(:image) { instance_double('AttachedImage', attached?: true) }
    let(:provider) { 'azure_document_intelligence' }
    let(:client) { instance_double(Ocr::Client) }
    let(:parser) { instance_double(Ocr::ResponseParser) }
    let(:raw_response) { { 'status' => 'ok' } }

    before do
      allow(Ocr::Client).to receive(:new).and_return(client)
      allow(Ocr::ResponseParser).to receive(:new).and_return(parser)
      allow(ExternalServiceStatus).to receive(:mark_success!)
      allow(ExternalServiceStatus).to receive(:mark_failure!)
    end

    context '正常系' do
      let(:parsed_response) do
        {
          success: true,
          raw_text: 'サンプルストア\nコーヒー 180',
          lines: [ 'サンプルストア', 'コーヒー 180' ],
          candidates: {
            store_name: 'サンプルストア',
            purchased_at_text: nil,
            total_amount: 180,
            payment_method_text: 'master'
          },
          error_code: nil,
          meta: {
            provider: provider,
            model_id: 'prebuilt-receipt'
          }
        }
      end

      it 'Ocr::Client と Ocr::ResponseParser を正しい引数で呼び、success: true をそのまま返す' do
        allow(client).to receive(:call).and_return(raw_response)
        allow(parser).to receive(:call).and_return(parsed_response)

        result = described_class.call(image, provider: provider)

        aggregate_failures do
          expect(Ocr::Client).to have_received(:new).with(image: image, provider: provider)
          expect(client).to have_received(:call)
          expect(Ocr::ResponseParser).to have_received(:new).with(response: raw_response, provider: provider)
          expect(parser).to have_received(:call)
          expect(result).to eq(parsed_response)
          expect(result[:success]).to eq(true)
          expect(ExternalServiceStatus).to have_received(:mark_success!).with(:ocr)
        end
      end
    end

    context 'parser が success: false を返す場合' do
      let(:parsed_response) do
        {
          success: false,
          raw_text: '',
          lines: [],
          candidates: {
            store_name: nil,
            purchased_at_text: nil,
            total_amount: nil,
            payment_method_text: nil
          },
          error_code: 'ocr_api_error',
          meta: {
            provider: provider
          }
        }
      end

      it '失敗結果をそのまま返す' do
        allow(client).to receive(:call).and_return(raw_response)
        allow(parser).to receive(:call).and_return(parsed_response)

        result = described_class.call(image, provider: provider)

        aggregate_failures do
          expect(result).to eq(parsed_response)
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ocr_api_error')
          expect(ExternalServiceStatus).to have_received(:mark_failure!).with(:ocr, error_code: 'ocr_api_error')
        end
      end
    end

    context '画像未添付の場合' do
      let(:image) { instance_double('AttachedImage', attached?: false) }

      it 'image_missing を返す' do
        result = described_class.call(image, provider: provider)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('image_missing')
          expect(result[:raw_text]).to eq('')
          expect(result[:lines]).to eq([])
          expect(result[:candidates]).to include(
            store_name: nil,
            purchased_at_text: nil,
            total_amount: nil,
            payment_method_text: nil
          )
          expect(result.dig(:meta, :provider)).to eq(provider)
          expect(ExternalServiceStatus).not_to have_received(:mark_success!)
          expect(ExternalServiceStatus).to have_received(:mark_failure!).with(:ocr, error_code: 'image_missing')
        end
      end
    end

    context 'OcrError が発生した場合' do
      it 'error_code を保ったまま失敗結果を返す' do
        allow(client).to receive(:call).and_raise(ReceiptOcrService::OcrError.new('ocr_api_error', 'api failed'))

        result = described_class.call(image, provider: provider)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ocr_api_error')
          expect(result.dig(:meta, :provider)).to eq(provider)
          expect(ExternalServiceStatus).to have_received(:mark_failure!).with(:ocr, error_code: 'ocr_api_error')
        end
      end
    end

    context 'タイムアウトが発生した場合' do
      it 'ocr_timeout を返す' do
        allow(client).to receive(:call).and_raise(Timeout::Error)

        result = described_class.call(image, provider: provider)

        aggregate_failures do
          expect(result[:error_code]).to eq('ocr_timeout')
          expect(ExternalServiceStatus).to have_received(:mark_failure!).with(:ocr, error_code: 'ocr_timeout')
        end
      end
    end

    context 'ActiveStorage::FileNotFoundError が発生した場合' do
      it 'image_corrupted を返す' do
        allow(client).to receive(:call).and_raise(ActiveStorage::FileNotFoundError)

        result = described_class.call(image, provider: provider)

        aggregate_failures do
          expect(result[:error_code]).to eq('image_corrupted')
          expect(ExternalServiceStatus).to have_received(:mark_failure!).with(:ocr, error_code: 'image_corrupted')
        end
      end
    end

    context '想定外エラーが発生した場合' do
      it 'unexpected_error を返す' do
        allow(client).to receive(:call).and_raise(StandardError, 'unexpected failure')

        result = described_class.call(image, provider: provider)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('unexpected_error')
          expect(result[:raw_text]).to eq('')
          expect(result[:lines]).to eq([])
          expect(ExternalServiceStatus).to have_received(:mark_failure!).with(:ocr, error_code: 'unexpected_error')
        end
      end
    end
  end
end
