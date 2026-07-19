require 'rails_helper'

RSpec.describe 'action_cable_log_redaction' do
  let(:logger) { ActionCable.server.logger }

  it 'ActionCable専用loggerを使用する' do
    aggregate_failures do
      expect(logger.class.name).to eq('Recify::ActionCableLogger')
      expect(Rails.logger.class.name).not_to eq('Recify::ActionCableLogger')
    end
  end

  it 'unsubscribe logのsigned stream capabilityをredactする' do
    message = 'Unsubscribing from channel: {"channel":"Turbo::StreamsChannel","signed_stream_name":"short-capability"}'

    allow(Rails.logger).to receive(:info)
    logger.info(message)

    aggregate_failures do
      expect(Rails.logger).to have_received(:info).with(include('[FILTERED_ACTION_CABLE_STREAM]'))
      expect(Rails.logger).not_to have_received(:info).with(include('short-capability'))
    end
  end

  it 'block形式のbroadcast logからstream識別子とpayloadをredactする' do
    captured_message = nil
    allow(Rails.logger).to receive(:debug) do |message = nil, &block|
      captured_message = message || block&.call
    end

    logger.debug do
      '[ActionCable] Broadcasting to Z2lkOi8vcmVjaWZ5L1VzZXIvMTIz:notifications: ' \
        '"<turbo-stream>receipt details</turbo-stream>"'
    end

    aggregate_failures do
      expect(captured_message).to include('[FILTERED_ACTION_CABLE_STREAM]')
      expect(captured_message).to include('[FILTERED_ACTION_CABLE_PAYLOAD]')
      expect(captured_message).not_to include('Z2lkOi8vcmVjaWZ5L1VzZXIvMTIz', 'receipt details')
    end
  end

  it 'Logger addのdirect messageとblock messageをredactする' do
    captured_messages = []
    allow(Rails.logger).to receive(:add) do |_severity, message = nil, _progname = nil, &block|
      captured_messages << (message || block&.call)
    end

    logger.add(Logger::INFO, 'signed_stream_name=direct-capability')
    logger.add(Logger::INFO) { 'signed_stream_name=block-capability' }

    aggregate_failures do
      expect(captured_messages).to all(include('[FILTERED_ACTION_CABLE_STREAM]'))
      expect(captured_messages.join).not_to include('direct-capability', 'block-capability')
    end
  end
end
