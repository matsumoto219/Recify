require 'rails_helper'

RSpec.describe 'Solid Cable receipt stream delivery' do
  self.use_transactional_tests = false

  let(:production_config) do
    ActiveSupport::OrderedOptions.new.update(Rails.application.config_for('cable', env: 'production').except(:connects_to))
  end
  let(:owner) { User.new(id: 123) }
  let(:other_user) { User.new(id: 456) }

  def queue_pop(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def subscribe_to(streamables)
    signed_name = Turbo::StreamsChannel.signed_stream_name(streamables)
    stream_name = Turbo::StreamsChannel.verified_stream_name(signed_name)
    received = Queue.new
    subscribed = Queue.new
    @server.pubsub.subscribe(stream_name, ->(payload) { received << payload }, -> { subscribed << true })
    queue_pop(subscribed)
    received
  end

  def stop_adapter
    @server.pubsub.shutdown
    @adapter_stopped = true
  end

  before do
    raise 'Solid Cable integration requires the test environment' unless Rails.env.test?
    unless %w[recify_test recify_bot_cable_test].include?(ActiveRecord::Base.connection_db_config.database)
      raise 'Solid Cable integration requires an approved test database'
    end

    if SolidCable::Record.connection_specification_name != ActiveRecord::Base.connection_specification_name
      @original_connection = SolidCable::Record.connection_db_config
    end
    @schema_name = "solid_cable_spec_#{Process.pid}_#{SecureRandom.hex(6)}"
    ActiveRecord::Base.connection.execute("CREATE SCHEMA #{@schema_name}")
    @schema_created = true
    connection_config = ActiveRecord::Base.connection_db_config.configuration_hash.merge(schema_search_path: @schema_name)
    SolidCable::Record.establish_connection(connection_config)
    @connection_switched = true
    SolidCable::Record.connection.create_table(:solid_cable_messages) do |table|
      table.binary :channel, null: false
      table.bigint :channel_hash, null: false
      table.datetime :created_at, null: false
      table.binary :payload, null: false
      table.index :channel
      table.index :channel_hash
      table.index :created_at
    end
    SolidCable::Message.reset_column_information

    allow(Rails.application).to receive(:config_for).and_call_original
    allow(Rails.application).to receive(:config_for).with('cable').and_return(production_config)
    SolidCable.reset_configuration! if SolidCable.respond_to?(:reset_configuration!)
    server_config = ActionCable.server.config.dup
    server_config.cable = production_config.stringify_keys
    @server = ActionCable::Server::Base.new(config: server_config)
    @executor = Concurrent::SingleThreadExecutor.new
    allow(@server).to receive(:event_loop).and_return(@executor)
    allow(ActionCable).to receive(:server).and_return(@server)
  end

  after do
    @server.pubsub.shutdown if @server && !@adapter_stopped
    @executor&.shutdown
    @executor&.wait_for_termination(5)
  ensure
    begin
      if @connection_switched
        SolidCable::Record.remove_connection
        SolidCable::Record.establish_connection(@original_connection) if @original_connection
        SolidCable::Message.reset_column_information
      end
      ActiveRecord::Base.connection.execute("DROP SCHEMA IF EXISTS #{@schema_name} CASCADE") if @schema_created
    ensure
      SolidCable.reset_configuration! if @connection_switched && SolidCable.respond_to?(:reset_configuration!)
    end
  end

  it 'receipt更新の連続配信と通知を利用者ごとのstreamへ順番通りに届ける' do
    owner_receipts = subscribe_to([ owner, :receipts ])
    other_receipts = subscribe_to([ other_user, :receipts ])
    owner_notifications = subscribe_to([ owner, :notifications ])
    other_notifications = subscribe_to([ other_user, :notifications ])

    12.times do |index|
      Turbo::StreamsChannel.broadcast_replace_to([ owner, :receipts ], target: 'receipt_card', html: "phase-#{index}")
    end
    Turbo::StreamsChannel.broadcast_replace_to([ other_user, :receipts ], target: 'receipt_card', html: 'other-receipt')
    Turbo::StreamsChannel.broadcast_replace_to([ owner, :notifications ], target: 'notifications_unread_badge', html: 'owner-notification')
    Turbo::StreamsChannel.broadcast_replace_to([ other_user, :notifications ], target: 'notifications_unread_badge', html: 'other-notification')
    receipt_payloads = 12.times.map { queue_pop(owner_receipts) }
    other_receipt_payload = queue_pop(other_receipts)
    owner_notification_payload = queue_pop(owner_notifications)
    other_notification_payload = queue_pop(other_notifications)
    stop_adapter

    aggregate_failures do
      expect(receipt_payloads.map { |payload| Nokogiri::HTML.fragment(ActiveSupport::JSON.decode(payload)).at_css('template').text }).to eq(12.times.map { |index| "phase-#{index}" })
      expect(other_receipt_payload).to include('other-receipt')
      expect(owner_notification_payload).to include('owner-notification')
      expect(other_notification_payload).to include('other-notification')
      expect([ owner_receipts, other_receipts, owner_notifications, other_notifications ]).to all(be_empty)
    end
  end

  it '停止時に受付済のreceipt更新をすべて保存する' do
    stream_name = Turbo::StreamsChannel.verified_stream_name(Turbo::StreamsChannel.signed_stream_name([ owner, :receipts ]))
    write_started = Queue.new
    release_write = Queue.new
    shutdown_started = Queue.new
    paused = false
    allow(SolidCable::Message).to receive(:insert_all).and_wrap_original do |operation, *args, **kwargs|
      unless paused
        paused = true
        write_started << true
        queue_pop(release_write)
      end
      operation.call(*args, **kwargs)
    end

    12.times { |index| @server.pubsub.broadcast(stream_name, "phase-#{index}") }
    queue_pop(write_started)
    expect(SolidCable::Message.count).to eq(0)
    stopping = Thread.new do
      shutdown_started << true
      stop_adapter
    end
    queue_pop(shutdown_started)
    release_write << true
    Timeout.timeout(5) { stopping.value }

    aggregate_failures do
      expect(SolidCable::Message.order(:id).pluck(:payload)).to eq(12.times.map { |index| "phase-#{index}" })
      expect(SolidCable::Message.distinct.pluck(:channel)).to eq([ stream_name ])
    end
  ensure
    release_write << true if release_write
    stopping&.join(5)
  end

  it '期限切れmessageだけを削除し保持期間内のreceipt更新を残す' do
    current_message = SolidCable::Message.create!(channel: 'receipt-stream', channel_hash: SolidCable::Message.channel_hash_for('receipt-stream'), payload: 'current', created_at: 1.hour.ago)
    expired_message = SolidCable::Message.create!(channel: 'receipt-stream', channel_hash: SolidCable::Message.channel_hash_for('receipt-stream'), payload: 'expired', created_at: 2.days.ago)
    allow(SolidCable).to receive(:autotrim?).and_return(false)

    SolidCable::TrimJob.perform_now

    aggregate_failures do
      expect(SolidCable::Message.exists?(expired_message.id)).to be(false)
      expect(current_message.reload.payload).to eq('current')
    end
  end

  it '自動trimを伴う連続配信でも保持期間内のmessageを削除しない' do
    allow(SolidCable).to receive(:trim_batch_size).and_return(2)
    current_message = SolidCable::Message.create!(channel: 'receipt-stream', channel_hash: SolidCable::Message.channel_hash_for('receipt-stream'), payload: 'current', created_at: 1.hour.ago)
    expired_message = SolidCable::Message.create!(channel: 'receipt-stream', channel_hash: SolidCable::Message.channel_hash_for('receipt-stream'), payload: 'expired', created_at: 2.days.ago)
    stream_name = Turbo::StreamsChannel.verified_stream_name(Turbo::StreamsChannel.signed_stream_name([ owner, :receipts ]))

    12.times { |index| @server.pubsub.broadcast(stream_name, "phase-#{index}") }
    stop_adapter

    aggregate_failures do
      expect(SolidCable::Message.exists?(expired_message.id)).to be(false)
      expect(current_message.reload.payload).to eq('current')
      expect(SolidCable::Message.where(channel: stream_name).order(:id).pluck(:payload)).to eq(12.times.map { |index| "phase-#{index}" })
    end
  end

  it 'DB書込障害をpayloadなしで報告し復旧後のreceipt更新を届ける' do
    received = subscribe_to([ owner, :receipts ])
    reported_errors = Queue.new
    allow(Rails.error).to receive(:report) { |error, **context| reported_errors << [ error, context ] }
    allow(SolidCable::Message).to receive(:insert_all).and_raise(ActiveRecord::ConnectionNotEstablished, 'synthetic connection failure')

    Turbo::StreamsChannel.broadcast_replace_to([ owner, :receipts ], target: 'receipt_card', html: 'failed-update')
    reports = [ queue_pop(reported_errors) ]
    allow(SolidCable::Message).to receive(:insert_all).and_call_original
    Turbo::StreamsChannel.broadcast_replace_to([ owner, :receipts ], target: 'receipt_card', html: 'recovered-update')
    recovered_payload = queue_pop(received)
    stop_adapter
    reports << reported_errors.pop until reported_errors.empty?

    aggregate_failures do
      expect(reports.map(&:first)).to all(be_a(ActiveRecord::ConnectionNotEstablished))
      expect(reports.map { |_error, context| context.except(:handled, :source) }).to all(be_empty)
      expect(recovered_payload).to include('recovered-update')
      expect(recovered_payload).not_to include('failed-update')
      expect(SolidCable::Message.count).to eq(1)
      expect(received).to be_empty
    end
  end
end
