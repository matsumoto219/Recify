class ContactRequest < ApplicationRecord
  CATEGORIES = %w[
    bug
    account
    receipt_analysis
    security
    other
  ].freeze

  STATUSES = %w[
    open
    in_progress
    resolved
    closed
  ].freeze

  SOURCES = %w[
    authenticated
    guest
    public
  ].freeze

  belongs_to :user, optional: true
  belongs_to :handled_by_user, class_name: "User", optional: true

  before_validation :normalize_sender_name
  before_validation :ensure_request_uid

  validates :request_uid, presence: true, uniqueness: true
  validates :sender_name, length: { maximum: 50 }, allow_blank: true
  validates :email,
            presence: true,
            format: { with: URI::MailTo::EMAIL_REGEXP },
            length: { maximum: 255 }
  validates :email_digest, presence: true, length: { is: 64 }
  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :subject, presence: true, length: { maximum: 160 }
  validates :body, presence: true, length: { maximum: 5000 }
  validates :user_agent, length: { maximum: 1000 }, allow_blank: true
  validates :request_id, length: { maximum: 255 }, allow_blank: true

  scope :unresolved, -> { where(status: %w[open in_progress]) }
  scope :recent, -> { order(created_at: :desc) }

  private

  def normalize_sender_name
    self.sender_name = sender_name.to_s.strip.presence
  end

  def ensure_request_uid
    self.request_uid = self.class.generate_request_uid if request_uid.blank?
  end

  def self.generate_request_uid
    "cr_#{SecureRandom.alphanumeric(20).downcase}"
  end
end
