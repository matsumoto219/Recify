class UsageCounter < ApplicationRecord
  PERIODS = %w[day minute].freeze

  belongs_to :user

  validates :key, presence: true
  validates :period, presence: true, inclusion: { in: PERIODS }
  validates :period_start, presence: true
  validates :used_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :used_bytes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
