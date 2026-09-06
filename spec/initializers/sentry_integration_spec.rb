require 'rails_helper'
require 'sentry/transport/dummy_transport'

RSpec.describe 'Sentry SDK integration' do
  let(:initializer_path) { Rails.root.join('config/initializers/sentry.rb') }

  before do
    expect(Sentry::HTTPTransport).not_to receive(:new)
    expect(Sentry::SpotlightTransport).not_to receive(:new)
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SENTRY_DSN').and_return('https://public@example.test/1')
    allow(ENV).to receive(:[]).with('SENTRY_ENVIRONMENT').and_return('test')
    allow(ENV).to receive(:[]).with('SENTRY_RELEASE').and_return(nil)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('SENTRY_SAMPLE_RATE', 1.0).and_return(1.0)
    allow(ENV).to receive(:fetch).with('SENTRY_TRACES_SAMPLE_RATE', 0.0).and_return(0.0)
    allow(Sentry).to receive(:init).and_wrap_original do |original, &configure|
      original.call do |config|
        configure.call(config)
        config.transport.transport_class = Sentry::DummyTransport
        config.spotlight = false
        config.background_worker_threads = 0
        config.auto_session_tracking = false
        config.sdk_logger = Logger.new(IO::NULL)
        config.server_name = 'example.test'
        # Test literals are source code, not collected request/job data.
        config.context_lines = nil
        config.data_collection.frame_context_lines = nil
      end
    end
  end

  after do
    client = Sentry.get_current_client
    Sentry.close if Sentry.initialized?
  ensure
    [ client&.log_event_buffer, client&.metric_event_buffer ].compact.each do |buffer|
      buffer.kill
      buffer.thread&.join(1)
      expect(buffer.thread&.alive?).not_to be(true)
    end
  end

  it 'productionでもDSNがなければ初期化しない' do
    allow(ENV).to receive(:[]).with('SENTRY_DSN').and_return(nil)
    expect(Sentry).not_to receive(:init)

    load_initializer

    expect(Sentry).not_to be_initialized
  end

  it 'production以外ではDSNがあっても初期化しない' do
    allow(Rails.env).to receive(:production?).and_return(false)
    expect(Sentry).not_to receive(:init)

    load_initializer

    expect(Sentry).not_to be_initialized
  end

  it '既存のsampling環境変数を維持する' do
    allow(ENV).to receive(:fetch).with('SENTRY_SAMPLE_RATE', 1.0).and_return('0.5')
    allow(ENV).to receive(:fetch).with('SENTRY_TRACES_SAMPLE_RATE', 0.0).and_return('0.25')

    load_initializer

    expect(Sentry.configuration.sample_rate).to eq(0.5)
    expect(Sentry.configuration.traces_sample_rate).to eq(0.25)
  end

  it '不正なsampling値は既存defaultへ戻す' do
    allow(ENV).to receive(:fetch).with('SENTRY_SAMPLE_RATE', 1.0).and_return('invalid')
    allow(ENV).to receive(:fetch).with('SENTRY_TRACES_SAMPLE_RATE', 0.0).and_return('invalid')

    load_initializer

    expect(Sentry.configuration.sample_rate).to eq(1.0)
    expect(Sentry.configuration.traces_sample_rate).to eq(0.0)
  end

  context 'production用initializerを外部送信なしで実行した場合' do
    before do
      load_initializer
    end

    it '既存のPII非収集とsamplingをSDKの実設定へ適用する' do
      config = Sentry.configuration
      collection = config.data_collection

      aggregate_failures do
        expect(config.sample_rate).to eq(1.0)
        expect(config.traces_sample_rate).to eq(0.0)
        expect(config.breadcrumbs_logger).to eq([])
        expect(collection.user_info).to be(false)
        expect(collection.cookies.mode).to eq(:off)
        expect(collection.url_query_params.mode).to eq(:off)
        expect(collection.http_bodies).to eq([])
        expect(collection.collect_incoming_http_body?).to be(false)
        expect(collection.collect_outgoing_http_body?).to be(false)
        expect(collection.queues).to be(false)
        expect(collection.database_query_data).to be(false)
        expect(collection.graphql.document).to be(false)
        expect(collection.graphql.variables).to be(false)
        expect(collection.collect_stack_frame_variables?).to be(false)
      end
    end

    it 'Rails structured loggingのsubscriberを有効にしない' do
      expect(Sentry::Rails::StructuredLogging).not_to receive(:attach)

      Sentry::Railtie.instance.activate_structured_logging

      expect(Sentry.configuration.rails.structured_logging.enabled?).to be(false)
    end

    it '直接追加されたlogとmetricも送信payloadへ含めない' do
      Sentry.logger.info('synthetic receipt text', attributes: { signed_stream_name: 'short-capability' })
      Sentry.metrics.count('synthetic.receipt', value: 1, attributes: { raw_text: 'synthetic receipt text' })
      Sentry.get_current_client.flush

      payload = transport.envelopes.flat_map(&:items).map(&:serialize).join
      aggregate_failures do
        expect(transport.envelopes.flat_map { |envelope| envelope.items.map(&:type) }).not_to include('log', 'trace_metric')
        expect(payload).not_to include('synthetic receipt text', 'short-capability')
      end
    end

    it 'Rack例外を捕捉しrequest capabilityと機密情報を送信前に除く' do
      app = Sentry::Rails::CaptureExceptions.new(lambda do |_env|
        Sentry.set_extras(raw_text: 'synthetic OCR text', signed_stream_name: 'short-capability')
        raise 'synthetic failure token=test-secret'
      end)
      env = Rack::MockRequest.env_for(
        'https://example.test/rails/active_storage/blobs/redirect/signed-capability/file.png?token=query-secret',
        'HTTP_AUTHORIZATION' => 'Bearer header-secret',
        'HTTP_COOKIE' => 'session=cookie-secret'
      )

      expect { app.call(env) }.to raise_error(RuntimeError, 'synthetic failure token=test-secret')

      event = transport.events.fetch(0)
      aggregate_failures do
        expect(transport.events.size).to eq(1)
        expect(event.request.url).to eq(Recify::ActiveStorageLogRedactor::FILTERED_URL)
        expect(event.to_h.to_json).not_to include(
          'signed-capability',
          'query-secret',
          'header-secret',
          'cookie-secret',
          'test-secret',
          'synthetic OCR text',
          'short-capability'
        )
      end
    end

    it '実request interfaceがbodyとcookieとqueryを収集しない' do
      request = Sentry::RequestInterface.new(
        env: Rack::MockRequest.env_for(
          'https://example.test/receipts?token=query-secret',
          method: 'POST',
          input: '{"raw_text":"synthetic OCR text"}',
          'CONTENT_TYPE' => 'application/json',
          'HTTP_COOKIE' => 'session=cookie-secret'
        ),
        data_collection: Sentry.configuration.data_collection,
        rack_env_whitelist: Sentry.configuration.rack_env_whitelist
      )

      aggregate_failures do
        expect(request.data).to be_nil
        expect(request.cookies).to eq({})
        expect(request.query_string).to be_nil
      end
    end

    it 'ActiveJob失敗は捕捉し引数とuser情報を送信しない' do
      stub_const('SentryCompatibilityJob', Class.new(ActiveJob::Base) do
        def perform(_payload)
          raise 'synthetic job failure'
        end
      end)
      Sentry.set_user(email: 'synthetic@example.test')
      job = SentryCompatibilityJob.new(raw_text: 'synthetic job OCR text')
      allow(job).to receive(:logger).and_return(Logger.new(IO::NULL))

      expect { job.perform_now }.to raise_error(RuntimeError, 'synthetic job failure')

      aggregate_failures do
        expect(transport.events.size).to eq(1)
        expect(transport.events.first.to_h.to_json).not_to include('synthetic job OCR text', 'synthetic@example.test')
        expect(job.serialize.fetch('_sentry', {})).not_to have_key('user')
      end
    end

    it '明示的にsampleされたtransactionにも既存の秘匿化を適用する' do
      Sentry.set_extras(signed_stream_name: 'transaction-capability')
      transaction = Sentry.start_transaction(name: 'synthetic transaction', op: 'test', sampled: true)

      transaction.finish

      aggregate_failures do
        expect(transport.events.size).to eq(1)
        expect(transport.events.first.type).to eq('transaction')
        expect(transport.events.first.extra[:signed_stream_name]).to eq(Recify::SentrySanitizer::FILTERED)
      end
    end
  end

  def load_initializer
    silence_warnings { load initializer_path }
  end

  def transport
    Sentry.get_current_client.transport
  end
end
