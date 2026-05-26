class UserSession < ApplicationRecord
  ACTIVE_RETENTION_PERIOD = 30.days

  belongs_to :user

  validates :session_uid_digest, presence: true, uniqueness: true
  validates :session_version, presence: true
  validates :started_at, presence: true
  validates :last_seen_at, presence: true

  scope :active, -> {
    where(signed_out_at: nil, revoked_at: nil, expired_at: nil)
      .where("last_seen_at >= ?", ACTIVE_RETENTION_PERIOD.ago)
  }
end
