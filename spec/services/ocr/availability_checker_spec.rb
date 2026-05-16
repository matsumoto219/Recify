require 'rails_helper'

RSpec.describe Ocr::AvailabilityChecker do
  let(:client) { instance_double(Ocr::Client) }

  before do
    allow(Ocr::Client).to receive(:new).with(image: nil).and_return(client)
  end

  it 'OCR client が available の場合は true を返す' do
    allow(client).to receive(:available?).and_return(true)

    expect(described_class.call).to eq(true)
  end

  it 'OCR client が unavailable の場合は false を返す' do
    allow(client).to receive(:available?).and_return(false)

    expect(described_class.call).to eq(false)
  end

  it '例外時は false を返す' do
    allow(client).to receive(:available?).and_raise(Ocr::OcrError, 'ocr_api_error')

    expect(described_class.call).to eq(false)
  end
end
