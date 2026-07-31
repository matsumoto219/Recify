require 'rails_helper'

RSpec.describe SecurityEvents::Recorder do
  let(:request) do
    instance_double(
      ActionDispatch::Request,
      remote_ip: '203.0.113.25',
      user_agent: 'RSpec Browser',
      request_id: 'req-123',
      path: '/receipts',
      request_method: 'POST',
      env: {}
    )
  end

  it '親入口からsecurity eventを記録できる' do
    event = SecurityEvents.record!(
      event_type: 'sql_injection_attempt',
      severity: 'high',
      request: request,
      field_name: 'q',
      matched_rule: 'sql_comment',
      payload: "' OR 1=1 --"
    )

    expect(event).to be_persisted
    expect(event).to have_attributes(
      event_type: 'sql_injection_attempt',
      severity: 'high',
      ip_address: be_present,
      request_id: 'req-123',
      path: '/receipts',
      method: 'POST',
      field_name: 'q',
      matched_rule: 'sql_comment',
      payload_excerpt: "' OR 1=1 --",
      count: 1
    )
  end

  it 'XSS payloadをexcerptとして保存し、表示側でescapeできる形に留める' do
    event = described_class.call(
      event_type: 'xss_attempt',
      severity: 'high',
      request: request,
      payload: '<script>alert(1)</script>'
    )

    expect(event.payload_excerpt).to eq('<script>alert(1)</script>')
  end

  it 'secretやPIIをpayload excerptからredactする' do
    event = described_class.call(
      event_type: 'suspicious_payload',
      severity: 'medium',
      request: request,
      payload: 'email=user@example.com&password=secret123&Authorization: Bearer abcdefghijklmnopqrstuvwxyz'
    )

    expect(event.payload_excerpt).to include('[REDACTED_EMAIL]')
    expect(event.payload_excerpt).to include('password=[FILTERED]')
    expect(event.payload_excerpt).to include('Authorization: [FILTERED]')
    expect(event.payload_excerpt).not_to include('user@example.com', 'secret123', 'abcdefghijklmnopqrstuvwxyz')
  end

  it 'Active Storage URLをpathとpayload excerptからredactする' do
    storage_path = '/rails/active_storage/blobs/redirect/signed-id/file.png'
    event = described_class.call(
      event_type: 'suspicious_payload',
      severity: 'medium',
      request: request,
      path: storage_path,
      payload: "redirect=#{storage_path}"
    )

    aggregate_failures do
      expect(event.path).to eq(Recify::ActiveStorageLogRedactor::FILTERED_URL)
      expect(event.payload_excerpt).to eq("redirect=#{Recify::ActiveStorageLogRedactor::FILTERED_URL}")
      expect(event.path).not_to include('signed-id')
      expect(event.payload_excerpt).not_to include('signed-id')
    end
  end

  it '長いscanner pathを過剰redactせず別pathとして集約する' do
    first_path = "/#{'a' * 48}.php"
    second_path = "/#{'b' * 48}.php"

    first_event = described_class.call(
      event_type: 'rate_limit_triggered',
      severity: 'medium',
      request: request,
      path: first_path,
      matched_rule: 'fail2ban/scanner_paths'
    )
    second_event = described_class.call(
      event_type: 'rate_limit_triggered',
      severity: 'medium',
      request: request,
      path: second_path,
      matched_rule: 'fail2ban/scanner_paths'
    )

    aggregate_failures do
      expect(first_event.path).to eq(first_path)
      expect(second_event.path).to eq(second_path)
      expect(SecurityEvent.where(event_type: 'rate_limit_triggered').count).to eq(2)
    end
  end

  it 'pathをpayload上限ではなくSecurityEventのpath上限まで保持する' do
    long_path = "/#{Array.new(170) { |index| "segment-#{index}" }.join('/')}"
    expect(long_path.length).to be_between(1_001, SecurityEvent::PATH_MAX_LENGTH)

    event = described_class.call(
      event_type: 'rate_limit_triggered',
      severity: 'medium',
      request: request,
      path: long_path,
      matched_rule: 'fail2ban/scanner_paths'
    )

    expect(event.path).to eq(long_path)
  end

  it 'metadataからsecret風keyを除去する' do
    event = described_class.call(
      event_type: 'suspicious_payload',
      severity: 'medium',
      request: request,
      metadata: {
        safe: 'value',
        token: 'SECRET',
        nested: {
          api_key: 'KEY',
          count: 1
        }
      }
    )

    expect(event.metadata).to eq(
      'safe' => 'value',
      'nested' => { 'count' => 1 }
    )
  end

  it 'metadata内のURL secretやActive Storage情報をsafe化する' do
    event = described_class.call(
      event_type: 'suspicious_payload',
      severity: 'medium',
      request: request,
      metadata: {
        target_url: 'https://user:pass@example.com/path?token=secret#fragment',
        blob_key: 'raw-storage-key',
        preview_url: '/rails/active_storage/representations/redirect/signed-id/preview.png'
      }
    )

    aggregate_failures do
      expect(event.metadata).to include(
        'target_url' => 'https://example.com/path',
        'preview_url' => '[FILTERED_STORAGE_URL]'
      )
      expect(event.metadata).not_to include('blob_key')
      expect(event.metadata.to_json).not_to include('secret', 'signed-id', 'raw-storage-key')
    end
  end

  it '長いpayloadを切り詰める' do
    event = described_class.call(
      event_type: 'suspicious_payload',
      severity: 'medium',
      request: request,
      payload: ('safe text ' * 120)
    )

    expect(event.payload_excerpt.bytesize).to eq(SecurityEvent::PAYLOAD_EXCERPT_MAX_BYTES)
  end

  it 'binary payloadは保存しない' do
    event = described_class.call(
      event_type: 'suspicious_payload',
      severity: 'medium',
      request: request,
      payload: "abc\x00def"
    )

    expect(event.payload_excerpt).to be_nil
    expect(event.payload_sha256).to be_nil
  end

  it '同一eventは新規作成せずcountを更新する' do
    2.times do
      described_class.call(
        event_type: 'path_traversal_attempt',
        severity: 'high',
        request: request,
        path: '/receipts',
        payload: '../config/master.key'
      )
    end

    expect(SecurityEvent.count).to eq(1)
    expect(SecurityEvent.first.count).to eq(2)
  end

  it '遅れて到着したeventを集約してもfirst/last seenを発生順に保つ' do
    latest_occurred_at = Time.current.change(usec: 0)
    earliest_occurred_at = latest_occurred_at - 5.minutes
    attributes = {
      event_type: 'path_traversal_attempt',
      severity: 'high',
      request: request,
      path: '/receipts',
      payload: '../config/master.key'
    }
    event = described_class.call(**attributes, occurred_at: latest_occurred_at)

    described_class.call(**attributes, occurred_at: earliest_occurred_at)

    expect(event.reload).to have_attributes(
      count: 2,
      first_seen_at: earliest_occurred_at,
      last_seen_at: latest_occurred_at
    )
  end

  it '既存rowのfirst/last seenが逆転していても次の集約時に時系列を修復する' do
    occurred_at = Time.current.change(usec: 0)
    attributes = {
      event_type: 'path_traversal_attempt',
      severity: 'high',
      request: request,
      path: '/receipts',
      payload: '../config/master.key'
    }
    event = described_class.call(**attributes, occurred_at: occurred_at)
    event.update_columns(
      first_seen_at: occurred_at,
      last_seen_at: occurred_at - 5.minutes
    )

    described_class.call(**attributes, occurred_at: occurred_at + 5.minutes)

    expect(event.reload).to have_attributes(
      count: 2,
      first_seen_at: occurred_at - 5.minutes,
      last_seen_at: occurred_at + 5.minutes
    )
  end

  context 'aggregation identity' do
    let(:identity_attributes) do
      {
        event_type: 'path_traversal_attempt',
        severity: 'high',
        ip_address: '192.0.2.25',
        path: '/receipts',
        method: 'POST',
        field_name: 'q',
        matched_rule: 'path_traversal',
        payload: '../config/master.key'
      }
    end

    {
      severity: 'medium',
      method: 'GET',
      field_name: 'redirect_to',
      matched_rule: 'alternate_path_traversal'
    }.each do |attribute, alternate_value|
      it "#{attribute}が異なるeventを別々に記録する" do
        described_class.call(**identity_attributes)
        described_class.call(**identity_attributes.merge(attribute => alternate_value))

        events = SecurityEvent.where(
          event_type: identity_attributes.fetch(:event_type),
          ip_address: identity_attributes.fetch(:ip_address),
          path: identity_attributes.fetch(:path)
        )

        expect(events.pluck(:count)).to contain_exactly(1, 1)
      end
    end

    it 'actorが異なるeventを別々に記録する' do
      first_actor = create(:user)
      second_actor = create(:user)

      described_class.call(**identity_attributes, actor_user: first_actor)
      described_class.call(**identity_attributes, actor_user: second_actor)

      events = SecurityEvent.where(
        event_type: identity_attributes.fetch(:event_type),
        ip_address: identity_attributes.fetch(:ip_address),
        path: identity_attributes.fetch(:path)
      )

      aggregate_failures do
        expect(events.pluck(:count)).to contain_exactly(1, 1)
        expect(events.pluck(:actor_user_id)).to contain_exactly(first_actor.id, second_actor.id)
      end
    end
  end

  context '同一identityの同時初回記録' do
    self.use_transactional_tests = false

    let(:race_marker) { "recorder-race-#{SecureRandom.hex(8)}" }
    let(:race_attributes) do
      {
        event_type: 'path_traversal_attempt',
        severity: 'high',
        ip_address: '192.0.2.26',
        path: '/synthetic/security-events-race',
        method: 'GET',
        field_name: 'path',
        matched_rule: race_marker,
        payload: race_marker
      }
    end

    after do
      SecurityEvent.where(
        ip_address: race_attributes.fetch(:ip_address),
        path: race_attributes.fetch(:path),
        matched_rule: race_marker
      ).delete_all
    end

    it '初回insertが並行しても1 rowへ集約する' do
      barrier_mutex = Mutex.new
      barrier_condition = ConditionVariable.new
      arrivals = 0
      errors = Queue.new
      recorders = 2.times.map do
        described_class.new(**race_attributes).tap do |recorder|
          recorder.define_singleton_method(:aggregation_candidate) do
            candidate = super()
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5

            barrier_mutex.synchronize do
              arrivals += 1
              barrier_condition.broadcast

              while arrivals < 2
                remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                break unless remaining.positive?

                barrier_condition.wait(barrier_mutex, remaining)
              end
            end

            candidate
          end
        end
      end
      threads = recorders.map do |recorder|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection { recorder.call }
        rescue StandardError => error
          errors << error
        end
      end

      threads.each(&:join)
      raise errors.pop unless errors.empty?

      events = SecurityEvent.where(
        ip_address: race_attributes.fetch(:ip_address),
        path: race_attributes.fetch(:path),
        matched_rule: race_marker
      )

      aggregate_failures do
        expect(events.count).to eq(1)
        expect(events.sum(:count)).to eq(2)
      end
    end
  end

  it 'aggregation identityをSQLへ埋め込まずdatabase advisory transaction lockを取得する' do
    connection = SecurityEvent.connection
    unsafe_rule = "rule'); SELECT pg_sleep(1); --"
    allow(SecurityEvent).to receive(:connection).and_return(connection)
    expect(connection).to receive(:exec_query)
      .with(
        'SELECT pg_advisory_xact_lock($1, $2) IS NULL AS lock_result_ignored',
        'SecurityEvents::Recorder',
        satisfy do |binds|
          values = binds.map(&:value_for_database)
          values.size == 2 &&
            values.all?(Integer) &&
            values.first == described_class::ADVISORY_LOCK_NAMESPACE
        end,
        prepare: true
      )
      .and_call_original

    described_class.call(
      event_type: 'path_traversal_attempt',
      severity: 'high',
      request: request,
      matched_rule: unsafe_rule,
      payload: '../config/master.key'
    )
  end

  it 'retention cleanupとの競合で集約候補が消えても発生中のeventを再記録する' do
    recorder = described_class.new(
      event_type: 'path_traversal_attempt',
      severity: 'high',
      request: request,
      path: '/receipts',
      payload: '../config/master.key'
    )
    attempts = 0
    allow(recorder).to receive(:aggregation_candidate).and_wrap_original do |original|
      attempts += 1
      raise ActiveRecord::RecordNotFound if attempts == 1

      original.call
    end

    event = recorder.call

    aggregate_failures do
      expect(attempts).to eq(2)
      expect(event).to be_persisted
      expect(event).to have_attributes(
        event_type: 'path_traversal_attempt',
        severity: 'high',
        count: 1,
        payload_excerpt: '../config/master.key'
      )
    end
  end

  it 'retention cleanup競合の再試行回数を上限付きにする' do
    recorder = described_class.new(
      event_type: 'path_traversal_attempt',
      severity: 'high',
      request: request,
      path: '/receipts',
      payload: '../config/master.key'
    )
    attempts = 0
    allow(recorder).to receive(:aggregation_candidate) do
      attempts += 1
      raise ActiveRecord::RecordNotFound
    end

    expect { recorder.call }.to raise_error(ActiveRecord::RecordNotFound)
    expect(attempts).to eq(described_class::STALE_CANDIDATE_RETRY_LIMIT + 1)
  end

  it 'retention cleanupとの競合に備えて集約候補を最初のSELECTでlockする' do
    attributes = {
      event_type: 'path_traversal_attempt',
      severity: 'high',
      request: request,
      path: '/receipts',
      payload: '../config/master.key'
    }
    described_class.call(**attributes)
    statements = []
    subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
      statements << payload[:sql] unless payload[:cached]
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      described_class.call(**attributes)
    end

    aggregation_select = statements.find do |statement|
      statement.include?('FROM "security_events"') &&
        statement.include?('"security_events"."event_type"') &&
        statement.include?('"security_events"."last_seen_at"')
    end

    expect(aggregation_select).to include('FOR UPDATE')
  end

  it 'SystemSettingsの集約窓を過ぎたeventは新規作成する' do
    create(:system_setting, key: 'security_events.aggregation_window_minutes', value: SystemSettings.stored_value(5))
    event = described_class.call(
      event_type: 'path_traversal_attempt',
      severity: 'high',
      request: request,
      path: '/receipts',
      payload: '../config/master.key'
    )
    event.update!(last_seen_at: 10.minutes.ago)

    described_class.call(
      event_type: 'path_traversal_attempt',
      severity: 'high',
      request: request,
      path: '/receipts',
      payload: '../config/master.key'
    )

    expect(SecurityEvent.count).to eq(2)
  end

  it 'resolved済みeventは集約せず新規作成する' do
    event = described_class.call(
      event_type: 'path_traversal_attempt',
      severity: 'high',
      request: request,
      payload: '../config/master.key'
    )
    event.update!(resolved_at: Time.current)

    described_class.call(
      event_type: 'path_traversal_attempt',
      severity: 'high',
      request: request,
      payload: '../config/master.key'
    )

    expect(SecurityEvent.count).to eq(2)
  end
end
