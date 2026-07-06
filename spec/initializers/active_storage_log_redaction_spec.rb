require 'rails_helper'

RSpec.describe 'active_storage_log_redaction' do
  let(:storage_url) { 'http://localhost:3000/rails/active_storage/disk/encoded-key/file.png' }

  it 'request start logのActive Storage pathをredactする' do
    rack_logger = Rails::Rack::Logger.new(->(_env) { [ 200, {}, [] ] })
    request = instance_double(
      ActionDispatch::Request,
      raw_request_method: 'GET',
      filtered_path: '/rails/active_storage/blobs/redirect/signed-id/file.png',
      remote_ip: '127.0.0.1'
    )

    message = rack_logger.send(:started_request_message, request)

    aggregate_failures do
      expect(message).to include(Recify::ActiveStorageLogRedactor::FILTERED_URL)
      expect(message).not_to include('/rails/active_storage', 'signed-id')
    end
  end

  it 'controller redirect logのActive Storage URLをredactする' do
    message = capture_log_subscriber_message(ActionController::LogSubscriber.new, :redirect_to, location: storage_url)

    expect(message).to eq("Redirected to #{Recify::ActiveStorageLogRedactor::FILTERED_URL}")
  end

  it 'dispatch redirect logのActive Storage URLをredactする' do
    message = capture_log_subscriber_message(ActionDispatch::LogSubscriber.new, :redirect, location: storage_url)

    expect(message).to eq("Redirected to #{Recify::ActiveStorageLogRedactor::FILTERED_URL}")
  end

  it 'Active Storage service_url logのURLとkeyをredactする' do
    subscriber = ActiveStorage::LogSubscriber.new
    event = build_notification_event(url: storage_url, key: 'raw-storage-key')
    captured_message = nil

    allow(subscriber).to receive(:color) { |message, _color| message }
    allow(subscriber).to receive(:debug) do |_event, message|
      captured_message = message
    end

    subscriber.service_url(event)

    aggregate_failures do
      expect(captured_message).to include(Recify::ActiveStorageLogRedactor::FILTERED_URL)
      expect(captured_message).to include(Recify::ActiveStorageLogRedactor::FILTERED_KEY)
      expect(captured_message).not_to include('/rails/active_storage', 'encoded-key', 'raw-storage-key')
    end
  end

  def capture_log_subscriber_message(subscriber, method_name, payload)
    event = build_notification_event(payload)
    captured_message = nil

    allow(subscriber).to receive(:info) do |&block|
      captured_message = block.call
    end

    subscriber.public_send(method_name, event)
    captured_message
  end

  def build_notification_event(payload)
    ActiveSupport::Notifications::Event.new('test.event', Time.current, Time.current, SecureRandom.uuid, payload)
  end
end
