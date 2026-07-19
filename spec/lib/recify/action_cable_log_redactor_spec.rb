require 'rails_helper'

RSpec.describe Recify::ActionCableLogRedactor do
  it 'escaped identifier内のsigned stream capabilityをredactする' do
    message = 'Could not execute command from ({"identifier"=>"{\\"channel\\":\\"Turbo::StreamsChannel\\",\\"signed_stream_name\\":\\"short-capability\\"}"}) [RuntimeError - invalid]'

    redacted = described_class.redact(message)

    aggregate_failures do
      expect(redacted).to include('Turbo::StreamsChannel', 'RuntimeError', described_class::FILTERED_STREAM)
      expect(redacted).not_to include('short-capability')
    end
  end

  it 'keyのないsigned stream capabilityも形式でredactする' do
    capability = "#{'a' * 24}--#{'b' * 64}"

    redacted = described_class.redact("Invalid subscription #{capability}")

    aggregate_failures do
      expect(redacted).to include(described_class::FILTERED_STREAM)
      expect(redacted).not_to include(capability)
    end
  end

  it 'stream開始・停止logの識別子をredactする' do
    messages = [
      'Turbo::StreamsChannel is streaming from Z2lkOi8vcmVjaWZ5L1VzZXIvMTIz:notifications',
      'Turbo::StreamsChannel stopped streaming from Z2lkOi8vcmVjaWZ5L1VzZXIvMTIz:notifications'
    ]

    redacted = messages.map { |message| described_class.redact(message) }

    aggregate_failures do
      expect(redacted).to all(include(described_class::FILTERED_STREAM))
      expect(redacted.join).not_to include('Z2lkOi8vcmVjaWZ5L1VzZXIvMTIz')
    end
  end

  it 'broadcastとtransmit logのstream識別子とpayloadをredactする' do
    messages = [
      '[ActionCable] Broadcasting to Z2lkOi8vcmVjaWZ5L1VzZXIvMTIz:receipts: "<turbo-stream>receipt details</turbo-stream>"',
      'Turbo::StreamsChannel transmitting "<turbo-stream>receipt details</turbo-stream>" (via streamed from Z2lkOi8vcmVjaWZ5L1VzZXIvMTIz:receipts)'
    ]

    redacted = messages.map { |message| described_class.redact(message) }

    aggregate_failures do
      expect(redacted).to all(include(described_class::FILTERED_STREAM, described_class::FILTERED_PAYLOAD))
      expect(redacted.join).not_to include('Z2lkOi8vcmVjaWZ5L1VzZXIvMTIz', 'receipt details')
    end
  end

  it '対象外messageとnilを変更しない' do
    message = 'Successfully upgraded to WebSocket'
    original = message.dup

    aggregate_failures do
      expect(described_class.redact(message)).to eq(message)
      expect(message).to eq(original)
      expect(described_class.redact(nil)).to be_nil
    end
  end
end
