require 'rails_helper'

RSpec.describe Turbo::StreamsChannel, type: :channel do
  it '有効な署名だけを購読する' do
    user = User.new(id: 123)
    signed_stream_name = described_class.signed_stream_name([ user, :notifications ])
    stream_name = described_class.verified_stream_name(signed_stream_name)

    subscribe(signed_stream_name: signed_stream_name)

    aggregate_failures do
      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from(stream_name)
    end
  end

  it '不正な署名を拒否する' do
    subscribe(signed_stream_name: 'invalid-signed-stream')

    expect(subscription).to be_rejected
  end
end
