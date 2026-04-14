require 'rails_helper'

RSpec.describe Ocr::Client do
  let(:image_path) { Rails.root.join('spec/fixtures/files/receipt_sample.jpg') }
  let(:image) { Rack::Test::UploadedFile.new(image_path, 'image/jpeg') }
  let(:provider) { 'azure_document_intelligence' }
  let(:client) { described_class.new(image: image, provider: provider) }

  describe '#call' do
    let(:operation_location) do
      'https://example.cognitiveservices.azure.com/documentintelligence/documentModels/prebuilt-receipt/analyzeResults/123'
    end

    let(:succeeded_response) do
      {
        'status' => 'succeeded',
        'analyzeResult' => {
          'content' => 'sample receipt content',
          'documents' => [
            {
              'fields' => {
                'MerchantName' => { 'valueString' => 'Test Store' },
                'Total' => { 'valueCurrency' => { 'amount' => 1280 } }
              }
            }
          ]
        }
      }
    end

    before do
      allow(client).to receive(:submit_request).and_return(operation_location)
    end

    it 'submit_request の結果を使って poll_result を呼び、生レスポンスHashを返す' do
      allow(client).to receive(:poll_result).with(operation_location).and_return(succeeded_response)

      result = client.call

      aggregate_failures do
        expect(client).to have_received(:submit_request)
        expect(client).to have_received(:poll_result).with(operation_location)
        expect(result).to eq(succeeded_response)
        expect(result['status']).to eq('succeeded')
        expect(result.dig('analyzeResult', 'documents', 0, 'fields', 'MerchantName', 'valueString')).to eq('Test Store')
      end
    end

    it 'Faraday::TimeoutError は OcrTimeoutError(ocr_timeout) に変換する' do
      allow(client).to receive(:submit_request).and_raise(Faraday::TimeoutError.new('timeout'))

      expect do
        client.call
      end.to raise_error(Ocr::OcrTimeoutError, 'ocr_timeout')
    end

    it 'Faraday::ConnectionFailed は OcrError(external_service_unavailable) に変換する' do
      allow(client).to receive(:submit_request).and_raise(Faraday::ConnectionFailed.new('connection failed'))

      expect do
        client.call
      end.to raise_error(Ocr::OcrError, 'external_service_unavailable')
    end

    it '想定外例外は OcrError(unexpected_error) に変換する' do
      allow(client).to receive(:submit_request).and_raise(StandardError.new('boom'))

      expect do
        client.call
      end.to raise_error(Ocr::OcrError, 'unexpected_error')
    end
  end

  describe '#available?' do
    it 'call が成功すれば true を返す' do
      allow(client).to receive(:check_availability).and_return(true)

      expect(client.available?).to eq(true)
    end

    it 'OcrError の場合は false を返す' do
      allow(client).to receive(:check_availability).and_raise(Ocr::OcrError.new('ocr_api_error'))

      expect(client.available?).to eq(false)
    end

    it 'OcrTimeoutError の場合は false を返す' do
      allow(client).to receive(:check_availability).and_raise(Ocr::OcrTimeoutError.new('ocr_timeout'))

      expect(client.available?).to eq(false)
    end
  end

  describe '#handle_response_status!' do
    let(:response) { instance_double(Faraday::Response, status: status) }

    subject(:handle_status) { client.send(:handle_response_status!, response) }

    context '401 の場合' do
      let(:status) { 401 }

      it 'external_service_auth_error を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'external_service_auth_error')
      end
    end

    context '403 の場合' do
      let(:status) { 403 }

      it 'external_service_auth_error を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'external_service_auth_error')
      end
    end

    context '404 の場合' do
      let(:status) { 404 }

      it 'input_invalid を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'input_invalid')
      end
    end

    context '408 の場合' do
      let(:status) { 408 }

      it 'ocr_timeout を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrTimeoutError, 'ocr_timeout')
      end
    end

    context '429 の場合' do
      let(:status) { 429 }

      it 'external_service_unavailable を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'external_service_unavailable')
      end
    end

    context '500 の場合' do
      let(:status) { 500 }

      it 'external_service_unavailable を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'external_service_unavailable')
      end
    end

    context '422 の場合' do
      let(:status) { 422 }

      it 'ocr_api_error を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'ocr_api_error')
      end
    end
  end

  describe '#request_body' do
    it 'download を持つオブジェクトなら download 結果を返す' do
      downloadable = instance_double('Downloadable')
      allow(downloadable).to receive(:download).and_return('downloaded-binary')

      request_client = described_class.new(image: downloadable, provider: provider)

      expect(request_client.send(:request_body)).to eq('downloaded-binary')
    end

    it 'read を持つオブジェクトなら read 結果を返す' do
      readable = StringIO.new('io-binary')
      request_client = described_class.new(image: readable, provider: provider)

      expect(request_client.send(:request_body)).to eq('io-binary')
    end

    it 'それ以外はそのまま返す' do
      raw = 'raw-binary'
      request_client = described_class.new(image: raw, provider: provider)

      expect(request_client.send(:request_body)).to eq('raw-binary')
    end
  end
end
