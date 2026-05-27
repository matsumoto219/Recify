class RecoveryCode < ApplicationRecord
  belongs_to :user

  validates :code_digest, presence: true, uniqueness: true

  def used?
    used_at.present?
  end
end
