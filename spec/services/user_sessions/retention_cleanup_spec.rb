require 'rails_helper'

RSpec.describe UserSessions::RetentionCleanup do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-27 10:00:00')) { example.run }
  end

  def create_user_session(user:, **attributes)
    UserSession.create!(
      {
        user: user,
        session_uid_digest: SecureRandom.hex(32),
        session_version: user.session_version,
        started_at: 120.days.ago,
        last_seen_at: 120.days.ago
      }.merge(attributes)
    )
  end

  describe '.call' do
    it 'retention対象をdry-runで返し、削除しない' do
      user = create(:user, session_version: 3)
      signed_out = create_user_session(user: user, signed_out_at: 91.days.ago)
      revoked = create_user_session(user: user, revoked_at: 91.days.ago)
      expired = create_user_session(user: user, expired_at: 91.days.ago)
      inactive = create_user_session(user: user, last_seen_at: 91.days.ago)
      active = create_user_session(
        user: user,
        session_version: 3,
        started_at: 1.day.ago,
        last_seen_at: 1.day.ago
      )
      recent_signed_out = create_user_session(
        user: user,
        signed_out_at: 1.day.ago,
        last_seen_at: 120.days.ago
      )

      result = described_class.call(cutoff: 90.days.ago, dry_run: true)

      aggregate_failures do
        expect(result).to include(
          dry_run: true,
          cutoff: 90.days.ago,
          limit: 1000,
          expired_count: 4,
          deleted_count: 0,
          errors: []
        )
        expect(result[:sample_session_ids]).to match_array([ signed_out.id, revoked.id, expired.id, inactive.id ])
        expect(UserSession.where(id: [ signed_out.id, revoked.id, expired.id, inactive.id, active.id, recent_signed_out.id ]).count).to eq(6)
        expect(result.to_json).not_to include(signed_out.session_uid_digest)
        expect(result.to_json).not_to include('203.0.113.')
        expect(result.to_json).not_to include('RSpec Browser')
      end
    end

    it 'dry_run falseでは対象だけを削除する' do
      user = create(:user, session_version: 1)
      deletable = create_user_session(user: user, signed_out_at: 91.days.ago)
      active = create_user_session(
        user: user,
        session_version: 1,
        started_at: 1.hour.ago,
        last_seen_at: 1.hour.ago
      )

      result = described_class.call(cutoff: 90.days.ago, dry_run: false)

      aggregate_failures do
        expect(result[:expired_count]).to eq(1)
        expect(result[:deleted_count]).to eq(1)
        expect(UserSession.where(id: deletable.id)).not_to exist
        expect(UserSession.where(id: active.id)).to exist
      end
    end

    it '現在session_versionと一致するactive sessionは削除対象にしない' do
      user = create(:user, session_version: 5)
      active = create_user_session(
        user: user,
        session_version: 5,
        started_at: 2.days.ago,
        last_seen_at: 2.days.ago
      )
      old_version = create_user_session(
        user: user,
        session_version: 4,
        started_at: 120.days.ago,
        last_seen_at: 91.days.ago
      )

      result = described_class.call(cutoff: 90.days.ago, dry_run: true)

      aggregate_failures do
        expect(result[:sample_session_ids]).to contain_exactly(old_version.id)
        expect(result[:sample_session_ids]).not_to include(active.id)
      end
    end

    it 'limitを守り、sample_session_idsは20件に制限する' do
      user = create(:user)
      sessions = Array.new(25) { create_user_session(user: user, signed_out_at: 91.days.ago) }

      result = described_class.call(cutoff: 90.days.ago, limit: 25, dry_run: true)

      aggregate_failures do
        expect(result[:expired_count]).to eq(25)
        expect(result[:sample_session_ids].size).to eq(20)
        expect(result[:sample_session_ids]).to eq(sessions.map(&:id).first(20))
      end
    end
  end
end
