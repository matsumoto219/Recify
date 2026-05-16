require 'rails_helper'

RSpec.describe Ai::AvailabilityChecker do
  let(:client) { instance_double(Ai::Client) }

  before do
    allow(Ai::Client).to receive(:new).and_return(client)
  end

  it 'AI client が success result を返す場合は true を返す' do
    allow(client).to receive(:call).with(hash_including(:filtered_content)).and_return({ success: true })

    expect(described_class.call).to eq(true)
  end

  it 'AI client が failure result を返す場合は false を返す' do
    allow(client).to receive(:call).with(hash_including(:filtered_content)).and_return({ success: false, error_code: 'ai_api_error' })

    expect(described_class.call).to eq(false)
  end

  it '例外時は false を返す' do
    allow(client).to receive(:call).with(hash_including(:filtered_content)).and_raise(Ai::Errors::ProviderError.new(message: 'boom', error_code: 'ai_api_error'))

    expect(described_class.call).to eq(false)
  end
end
