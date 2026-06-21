class LegalDocument < ApplicationRecord
  DOCUMENT_TYPES = %w[terms privacy].freeze
  STATUSES = %w[draft published archived].freeze
  VERSION_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/

  has_many :legal_acceptances, dependent: :restrict_with_error

  validates :document_type, presence: true, inclusion: { in: DOCUMENT_TYPES }
  validates :version,
            presence: true,
            format: { with: VERSION_FORMAT },
            uniqueness: { scope: %i[document_type locale] }
  validates :locale, presence: true
  validates :title, presence: true
  validates :source_path, presence: true, uniqueness: true
  validates :effective_on, :published_on, :last_updated_on, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :content_digest, presence: true
  validates :reconsent_required, :current, inclusion: { in: [ true, false ] }
  validates :current,
            uniqueness: {
              scope: %i[document_type locale],
              conditions: -> { where(current: true) }
            },
            if: :current?
  validate :current_document_must_be_published

  scope :published, -> { where(status: "published") }
  scope :current, -> { where(current: true) }

  def self.current!(document_type, locale: I18n.locale)
    published.find_by!(
      document_type: document_type.to_s,
      locale: locale.to_s,
      current: true
    )
  end

  private

  def current_document_must_be_published
    return unless current?
    return if status == "published"

    errors.add(:current, :invalid)
  end
end
