class TotpCredential < ApplicationRecord
  belongs_to :user

  encrypts :totp_secret

  validates :totp_secret, presence: true
  validates :user_id, uniqueness: true

  def confirmed?
    confirmed_at.present?
  end
end
