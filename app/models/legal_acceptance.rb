class LegalAcceptance < ApplicationRecord
  CONTEXTS = %w[signup guest_conversion reconsent admin_adjustment].freeze

  belongs_to :user
  belongs_to :legal_document

  validates :document_type, :version, :locale, :accepted_at, presence: true
  validates :acceptance_context, presence: true, inclusion: { in: CONTEXTS }
  validates :legal_document_id, uniqueness: { scope: :user_id }
  validates :version, uniqueness: { scope: %i[user_id document_type locale] }
  validates :user_agent, length: { maximum: 512 }, allow_nil: true
  validates :request_id, length: { maximum: 128 }, allow_nil: true
  validate :document_snapshot_matches_legal_document

  private

  def document_snapshot_matches_legal_document
    return if legal_document.blank?

    {
      document_type: legal_document.document_type,
      version: legal_document.version,
      locale: legal_document.locale
    }.each do |attribute, expected_value|
      actual_value = public_send(attribute).to_s
      next if actual_value == expected_value.to_s

      errors.add(attribute, :invalid)
    end
  end
end
