# frozen_string_literal: true

module LegalConsents
  class Requirement
    DOCUMENT_TYPES = %w[terms privacy].freeze

    def initialize(user:, locale: I18n.locale)
      @user = user
      @locale = locale.to_s
    end

    def required?
      missing_documents.any?
    end

    def required_documents
      return [] if user.blank? || user.guest?

      @required_documents ||= current_documents.select(&:reconsent_required?)
    end

    def missing_documents
      @missing_documents ||= required_documents.reject { |document| accepted_document_ids.include?(document.id) }
    end

    private

    attr_reader :user, :locale

    def current_documents
      @current_documents ||= DOCUMENT_TYPES.map { |document_type| LegalDocument.current!(document_type, locale: locale) }
    end

    def accepted_document_ids
      @accepted_document_ids ||= user.legal_acceptances.where(legal_document_id: required_documents.map(&:id)).pluck(:legal_document_id)
    end
  end
end
