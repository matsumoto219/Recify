require 'rails_helper'

RSpec.describe Admin::UsersQuery do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-26 12:00:00')) { example.run }
  end

  describe '.call' do
    it 'latest順で管理画面用recordを返す' do
      older = create(:user, email: 'older@example.com', created_at: 2.days.ago)
      newer = create(:user, email: 'newer@example.com', created_at: 1.day.ago)
      create(:passkey, user: newer, last_used_at: 1.hour.ago)
      create_list(:receipt, 2, user: newer)

      result = described_class.call
      record = result.records.first

      aggregate_failures do
        expect(result.records.map { |item| item[:id] }).to eq([ newer.id, older.id ])
        expect(record).to include(
          id: newer.id,
          email: 'newer@example.com',
          admin: false,
          guest: false,
          confirmed: true,
          locked: false,
          passkeys_count: 1,
          receipts_count: 2,
          latest_passkey_last_used_at: 1.hour.ago
        )
        expect(result.limit).to eq(50)
        expect(result.offset).to eq(0)
        expect(result.total_count).to eq(2)
      end
    end

    it 'email / admin / guest / confirmed / locked / has_passkeyで絞り込める' do
      target = create(:user, :admin, email: 'target-admin@example.com')
      create(:passkey, user: target)
      create(:user, email: 'normal@example.com')
      create(:user, :unconfirmed, email: 'pending@example.com')
      create(:user, email: 'guest@example.com', guest: true)
      locked = create(:user, email: 'locked@example.com', locked_at: 1.hour.ago)

      aggregate_failures do
        expect(described_class.call(email: 'TARGET').records.map { |record| record[:id] }).to eq([ target.id ])
        expect(described_class.call(admin: 'true').records.map { |record| record[:id] }).to eq([ target.id ])
        expect(described_class.call(guest: 'true').records.map { |record| record[:id] }).to eq([ User.find_by!(email: 'guest@example.com').id ])
        expect(described_class.call(confirmed: 'false').records.map { |record| record[:id] }).to eq([ User.find_by!(email: 'pending@example.com').id ])
        expect(described_class.call(locked: 'true').records.map { |record| record[:id] }).to eq([ locked.id ])
        expect(described_class.call(has_passkey: 'true').records.map { |record| record[:id] }).to eq([ target.id ])
      end
    end

    it 'limit上限とoffsetを適用する' do
      users = Array.new(3) { |index| create(:user, created_at: index.minutes.ago) }

      result = described_class.call(limit: 500, offset: 1)

      aggregate_failures do
        expect(result.limit).to eq(100)
        expect(result.offset).to eq(1)
        expect(result.total_count).to eq(3)
        expect(result.records.map { |record| record[:id] }).to eq(users.sort_by(&:created_at).reverse.drop(1).map(&:id))
      end
    end

    it 'passkey credentialや認証系カラムをrecordへ含めない' do
      user = create(:user)
      create(:passkey, user: user, credential_id: 'credential-secret-value', public_key: 'PUBLIC KEY SECRET')
      UserSession.create!(
        user: user,
        session_uid_digest: 'session-digest-secret-value',
        session_version: user.session_version,
        started_at: Time.current,
        last_seen_at: Time.current
      )
      user.update_column(:reset_password_token, 'RESET TOKEN SECRET')

      json = described_class.call(id: user.id).records.first.to_json

      aggregate_failures do
        expect(json).to include(user.email)
        expect(json).not_to include('credential-secret-value')
        expect(json).not_to include('PUBLIC KEY SECRET')
        expect(json).not_to include('encrypted_password')
        expect(json).not_to include('RESET TOKEN SECRET')
        expect(json).not_to include('reset_password_token')
        expect(json).not_to include('challenge')
        expect(json).not_to include('raw_response')
        expect(json).not_to include('prompt')
        expect(json).not_to include('session-digest-secret-value')
      end
    end

    it 'show用recordにactive session summaryを含める' do
      user = create(:user, session_version: 2)
      active = UserSession.create!(
        user: user,
        session_uid_digest: SecureRandom.hex(32),
        session_version: 2,
        started_at: 2.hours.ago,
        last_seen_at: 10.minutes.ago,
        ip_address: '203.0.113.30',
        user_agent: 'Session Browser',
        sign_in_method: 'password'
      )
      UserSession.create!(
        user: user,
        session_uid_digest: SecureRandom.hex(32),
        session_version: 1,
        started_at: 3.hours.ago,
        last_seen_at: 5.minutes.ago,
        sign_in_method: 'passkey'
      )

      record = described_class.find(id: user.id)

      aggregate_failures do
        expect(record.dig(:active_sessions, :count)).to eq(1)
        expect(record.dig(:active_sessions, :latest_seen_at)).to eq(active.last_seen_at)
        expect(record.dig(:active_sessions, :latest_sign_in_method)).to eq('password')
        expect(record.dig(:active_sessions, :latest_ip)).to eq('203.0.113.30')
        expect(record.dig(:active_sessions, :latest_user_agent)).to eq('Session Browser')
        expect(record.dig(:active_sessions, :recent)).to contain_exactly(
          hash_including(
            session_version: 2,
            started_at: active.started_at,
            last_seen_at: active.last_seen_at,
            sign_in_method: 'password',
            ip_address: '203.0.113.30',
            user_agent: 'Session Browser'
          )
        )
      end
    end

    it 'show用recordに利用量とeffective limit summaryを含める' do
      user = create(:user, storage_limit_bytes: 1.gigabyte)
      create(:user_limit_override, user: user, key: 'receipt_uploads_per_day', value: { 'value' => 75 }, expires_at: 1.day.from_now)
      create(:user_limit_override, user: user, key: 'storage_bytes', value: { 'value' => 2.gigabytes })
      create(:usage_counter, user: user, key: 'receipt_uploads_per_day', used_count: 3)
      create(:usage_counter, user: user, key: 'api_requests_per_day', used_count: 10)

      record = described_class.find(id: user.id)
      limit_rows = record.dig(:usage_limits, :limits).index_by { |row| row[:key] }

      aggregate_failures do
        expect(record.dig(:usage_limits, :storage, :base_limit_bytes)).to eq(1.gigabyte)
        expect(record.dig(:usage_limits, :storage, :effective_limit_bytes)).to eq(2.gigabytes)
        expect(record.dig(:usage_limits, :storage, :source)).to eq('override')
        expect(limit_rows.fetch('receipt_uploads_per_day')).to include(
          limit_value: 75,
          source: 'override',
          used_count: 3
        )
        expect(limit_rows.fetch('api_requests_per_day')).to include(
          limit_value: 1000,
          source: 'global_default',
          used_count: 10,
          api_reservation: true
        )
        expect(record.to_json).not_to include('secret', 'credential_id', 'session_uid')
      end
    end

    it 'show用recordのusage/limit summaryをkeyごとの個別queryにしない' do
      user = create(:user, storage_limit_bytes: 1.gigabyte)
      create(:user_limit_override, user: user, key: 'receipt_uploads_per_day', value: { 'value' => 75 }, expires_at: 1.day.from_now)
      create(:usage_counter, user: user, key: 'receipt_uploads_per_day', used_count: 3)

      queries = count_sql_queries do
        record = described_class.find(id: user.id)
        expect(record.dig(:usage_limits, :limits).size).to eq(UserLimits.definitions.size)
      end

      aggregate_failures do
        expect(queries.count { |sql| sql.include?('"usage_counters"') }).to eq(1)
        expect(queries.count { |sql| sql.include?('"user_limit_overrides"') }).to be <= 2
        expect(queries.count { |sql| sql.include?('"system_settings"') }).to eq(1)
      end
    end
  end

  describe '.find' do
    it 'idに一致するrecordを返す' do
      user = create(:user)

      expect(described_class.find(id: user.id)).to include(id: user.id, email: user.email)
    end

    it '存在しないidはnilを返す' do
      expect(described_class.find(id: 999_999)).to be_nil
    end
  end

  def count_sql_queries
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      name = payload[:name].to_s
      sql = payload[:sql].to_s.squish
      next if name == 'SCHEMA' || name == 'TRANSACTION' || payload[:cached]
      next if sql.include?('schema_migrations') || sql.include?('ar_internal_metadata')

      queries << sql
    end

    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        yield
      end
    end
    queries
  end
end
