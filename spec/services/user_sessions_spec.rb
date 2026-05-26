require 'rails_helper'

RSpec.describe UserSessions do
  include ActiveSupport::Testing::TimeHelpers

  let(:request) do
    instance_double(
      ActionDispatch::Request,
      remote_ip: '203.0.113.10',
      user_agent: 'RSpec Browser'
    )
  end

  around do |example|
    travel_to(Time.zone.parse('2026-05-27 10:00:00')) { example.run }
  end

  describe '.record_sign_in' do
    it 'session_uid生値をsessionだけに保存し、DBにはdigestのみ保存する' do
      user = create(:user, session_version: 2)
      session = {}

      record = described_class.record_sign_in(
        user: user,
        request: request,
        session: session,
        method: 'password'
      )

      raw_uid = session[:user_session_uid]

      aggregate_failures do
        expect(raw_uid).to be_present
        expect(record).to be_persisted
        expect(record.user).to eq(user)
        expect(record.session_uid_digest).to be_present
        expect(record.session_uid_digest).not_to eq(raw_uid)
        expect(UserSession.pluck(:session_uid_digest).join).not_to include(raw_uid)
        expect(record.session_version).to eq(2)
        expect(record.sign_in_method).to eq('password')
        expect(record.ip_address.to_s).to eq('203.0.113.10')
        expect(record.user_agent).to eq('RSpec Browser')
      end
    end

    it 'request nilでも壊れない' do
      user = create(:user)
      session = {}

      record = described_class.record_sign_in(
        user: user,
        request: nil,
        session: session,
        method: 'passkey'
      )

      aggregate_failures do
        expect(record).to be_persisted
        expect(record.ip_address).to be_nil
        expect(record.user_agent).to be_nil
      end
    end
  end

  describe '.touch_current' do
    it '現在sessionのlast_seen_atを更新する' do
      user = create(:user)
      session = {}
      record = described_class.record_sign_in(user: user, request: request, session: session, method: 'password')
      record.update!(last_seen_at: 10.minutes.ago)

      described_class.touch_current(user: user, request: request, session: session)

      expect(record.reload.last_seen_at).to eq(Time.current)
    end
  end

  describe '.record_sign_out' do
    it '現在sessionをsigned outにしてsession uidを消す' do
      user = create(:user)
      session = {}
      record = described_class.record_sign_in(user: user, request: request, session: session, method: 'password')

      described_class.record_sign_out(user: user, session: session)

      aggregate_failures do
        expect(record.reload.signed_out_at).to eq(Time.current)
        expect(session[:user_session_uid]).to be_nil
      end
    end
  end

  describe '.mark_revoked_for_user' do
    it '未sign outのsessionをrevokedにする' do
      user = create(:user)
      session = {}
      active = described_class.record_sign_in(user: user, request: request, session: session, method: 'password')
      signed_out = UserSession.create!(
        user: user,
        session_uid_digest: SecureRandom.hex(32),
        session_version: user.session_version,
        started_at: Time.current,
        last_seen_at: Time.current,
        signed_out_at: Time.current
      )

      count = described_class.mark_revoked_for_user(user: user)

      aggregate_failures do
        expect(count).to eq(1)
        expect(active.reload.revoked_at).to eq(Time.current)
        expect(signed_out.reload.revoked_at).to be_nil
      end
    end
  end

  describe '.active_for / .summary_for' do
    it '現在session_versionのactive sessionだけを返し、summaryを作る' do
      user = create(:user, session_version: 3)
      session = {}
      active = described_class.record_sign_in(user: user, request: request, session: session, method: 'password')
      old_version = UserSession.create!(
        user: user,
        session_uid_digest: SecureRandom.hex(32),
        session_version: 2,
        started_at: Time.current,
        last_seen_at: Time.current
      )
      signed_out = UserSession.create!(
        user: user,
        session_uid_digest: SecureRandom.hex(32),
        session_version: 3,
        started_at: Time.current,
        last_seen_at: Time.current,
        signed_out_at: Time.current
      )

      summary = described_class.summary_for(user: user)

      aggregate_failures do
        expect(described_class.active_for(user: user)).to contain_exactly(active)
        expect(described_class.active_for(user: user)).not_to include(old_version, signed_out)
        expect(summary.active_sessions_count).to eq(1)
        expect(summary.latest_seen_at).to eq(active.last_seen_at)
        expect(summary.latest_sign_in_method).to eq('password')
        expect(summary.latest_ip).to eq('203.0.113.10')
        expect(summary.latest_user_agent).to eq('RSpec Browser')
        expect(summary.recent_sessions).to contain_exactly(active)
      end
    end
  end
end
