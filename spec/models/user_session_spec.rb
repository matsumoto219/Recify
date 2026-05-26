require 'rails_helper'

RSpec.describe UserSession, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-27 10:00:00')) { example.run }
  end

  def build_user_session(attributes = {})
    described_class.new(
      {
        user: create(:user),
        session_uid_digest: SecureRandom.hex(32),
        session_version: 0,
        started_at: Time.current,
        last_seen_at: Time.current
      }.merge(attributes)
    )
  end

  it '有効なrecordを保存できる' do
    user_session = build_user_session

    expect(user_session).to be_valid
  end

  it 'session_uid_digestをuniqueにする' do
    digest = SecureRandom.hex(32)
    build_user_session(session_uid_digest: digest).save!

    duplicate = build_user_session(session_uid_digest: digest)

    expect(duplicate).not_to be_valid
  end

  it 'active scopeはsigned_out/revokedでなく30日以内に見えたsessionを返す' do
    active = build_user_session(last_seen_at: 1.hour.ago)
    signed_out = build_user_session(last_seen_at: 1.hour.ago, signed_out_at: Time.current)
    revoked = build_user_session(last_seen_at: 1.hour.ago, revoked_at: Time.current)
    marked_expired = build_user_session(last_seen_at: 1.hour.ago, expired_at: Time.current)
    expired = build_user_session(last_seen_at: 31.days.ago)
    [ active, signed_out, revoked, marked_expired, expired ].each(&:save!)

    expect(described_class.active).to contain_exactly(active)
  end

  it 'last_seen_atが30日より古いsessionをactive scopeから除外する' do
    recent = build_user_session(last_seen_at: 30.days.ago + 1.second)
    expired = build_user_session(last_seen_at: 30.days.ago - 1.second)
    [ recent, expired ].each(&:save!)

    expect(described_class.active).to contain_exactly(recent)
  end
end
