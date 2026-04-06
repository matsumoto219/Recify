require 'rails_helper'

RSpec.describe ReceiptOcrService do
  describe '.call' do
    let(:image) { double("image", attached?: true) }
    let(:client) { instance_double(Ocr::Client) }
    let(:parser) { instance_double(Ocr::ResponseParser) }

    before do
      allow(Ocr::Client).to receive(:new).and_return(client)
      allow(Ocr::ResponseParser).to receive(:new).and_return(parser)
    end

    context '正常系' do
      it 'success: true の場合はそのまま返す' do
        allow(client).to receive(:call).and_return("raw")
        allow(parser).to receive(:call).and_return({ success: true, lines: [] })

        result = described_class.call(image)

        expect(result[:success]).to be true
      end
    end

    context 'Parser失敗' do
      it 'success: false の場合はそのまま返す' do
        allow(client).to receive(:call).and_return("raw")
        allow(parser).to receive(:call).and_return({ success: false, error_code: "ocr_error" })

        result = described_class.call(image)

        expect(result[:success]).to be false
      end
    end

    context '画像未添付' do
      let(:image) { double("image", attached?: false) }

      it 'image_missingになる' do
        result = described_class.call(image)

        expect(result[:success]).to be false
        expect(result[:error_code]).to eq("image_missing")
      end
    end

    context 'タイムアウト' do
      it 'ocr_timeoutになる' do
        allow(client).to receive(:call).and_raise(Timeout::Error)

        result = described_class.call(image)

        expect(result[:error_code]).to eq("ocr_timeout")
      end
    end

    context '例外' do
      it 'unexpected_errorになる' do
        allow(client).to receive(:call).and_raise(StandardError)

        result = described_class.call(image)

        expect(result[:error_code]).to eq("unexpected_error")
      end
    end
  end
end
