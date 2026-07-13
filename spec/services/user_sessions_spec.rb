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

    it 'bang APIは追跡recordの保存失敗をcallerへ返す' do
      user = create(:user)
      session = {}

      allow(UserSession).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(UserSession.new))

      expect do
        described_class.record_sign_in!(
          user: user,
          request: request,
          session: session,
          method: 'guest'
        )
      end.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'best-effort APIは保存失敗時に未追跡session uidを残さない' do
      user = create(:user)
      session = {}

      allow(UserSession).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(UserSession.new))

      result = described_class.record_sign_in(
        user: user,
        request: request,
        session: session,
        method: 'password'
      )

      aggregate_failures do
        expect(result).to be_nil
        expect(session[:user_session_uid]).to be_nil
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

  describe '.revoke_all!' do
    it 'remember cookieの発行時刻を消し、session versionと追跡中sessionを原子的に失効する' do
      user = create(:user, session_version: 4)
      user.remember_me!
      tracked_session = described_class.record_sign_in(
        user: user,
        request: request,
        session: {},
        method: 'password'
      )

      revoked_count = described_class.revoke_all!(user: user)

      aggregate_failures do
        expect(revoked_count).to eq(1)
        expect(user.reload.session_version).to eq(5)
        expect(user.remember_created_at).to be_nil
        expect(tracked_session.reload.revoked_at).to eq(Time.current)
        expect(described_class.active_for(user: user)).to be_empty
      end
    end

    it '追跡sessionの失効に失敗した場合はremember情報とsession versionをrollbackする' do
      user = create(:user, session_version: 2)
      user.remember_me!
      remember_created_at = user.reload.remember_created_at
      relation = instance_double(ActiveRecord::Relation)

      allow(UserSession).to receive(:where).and_return(relation)
      allow(relation).to receive(:update_all).and_raise(ActiveRecord::StatementInvalid, 'local rollback fixture')

      expect do
        described_class.revoke_all!(user: user)
      end.to raise_error(ActiveRecord::StatementInvalid, 'local rollback fixture')

      aggregate_failures do
        expect(user.reload.session_version).to eq(2)
        expect(user.remember_created_at).to eq(remember_created_at)
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
