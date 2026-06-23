# frozen_string_literal: true

module LegalDocuments
  class CurrentStatus
    REQUIRED_DOCUMENT_TYPES = LegalDocument::DOCUMENT_TYPES.map(&:to_s).freeze

    Result = Struct.new(:ready, :locale, :documents, :missing_types, :checked_at, keyword_init: true) do
      def ready?
        ready == true
      end

      def missing?
        !ready?
      end
    end

    class << self
      def call(locale: I18n.locale)
        new(locale: locale).call
      end
    end

    def initialize(locale:)
      @locale = locale.to_s
    end

    def call
      documents = REQUIRED_DOCUMENT_TYPES.index_with do |document_type|
        document_payload(document_type, current_documents[document_type])
      end
      missing_types = documents.select { |_type, payload| !payload[:present] }.keys

      Result.new(
        ready: missing_types.empty?,
        locale: locale,
        documents: documents,
        missing_types: missing_types,
        checked_at: Time.current
      )
    end

    private

    attr_reader :locale

    def current_documents
      @current_documents ||= LegalDocument.published
                                           .current
                                           .where(document_type: REQUIRED_DOCUMENT_TYPES, locale: locale)
                                           .index_by(&:document_type)
    end

    def document_payload(document_type, document)
      base_payload = {
        document_type: document_type,
        locale: locale,
        present: document.present?
      }

      return base_payload if document.blank?

      base_payload.merge(
        id: document.id,
        version: document.version,
        status: document.status,
        current: document.current?,
        title: document.title,
        effective_on: document.effective_on,
        published_on: document.published_on,
        last_updated_on: document.last_updated_on,
        updated_at: document.updated_at
      )
    end
  end
end
