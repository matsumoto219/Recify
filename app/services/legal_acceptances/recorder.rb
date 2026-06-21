# frozen_string_literal: true

module LegalAcceptances
  class Recorder
    CURRENT_DOCUMENT_TYPES = %w[terms privacy].freeze

    def self.record_current!(document_type:, **kwargs)
      new(**kwargs).record_current!(document_type: document_type)
    end

    def self.record_current_documents!(...)
      new(...).record_current_documents!
    end

    def initialize(user:, acceptance_context:, request: nil, locale: I18n.locale, accepted_at: Time.current)
      @user = user
      @acceptance_context = acceptance_context.to_s
      @request = request
      @locale = locale.to_s
      @accepted_at = accepted_at
    end

    def record_current!(document_type:)
      legal_document = LegalDocument.current!(document_type, locale: locale)

      LegalAcceptance.find_or_create_by!(user: user, legal_document: legal_document) do |acceptance|
        acceptance.document_type = legal_document.document_type
        acceptance.version = legal_document.version
        acceptance.locale = legal_document.locale
        acceptance.accepted_at = accepted_at
        acceptance.acceptance_context = acceptance_context
        acceptance.ip_address = request&.remote_ip
        acceptance.user_agent = truncated(request&.user_agent, 512)
        acceptance.request_id = truncated(request&.request_id, 128)
      end
    end

    def record_current_documents!
      LegalAcceptance.transaction do
        CURRENT_DOCUMENT_TYPES.map { |document_type| record_current!(document_type: document_type) }
      end
    end

    private

    attr_reader :user, :acceptance_context, :request, :locale, :accepted_at

    def truncated(value, length)
      value.to_s.presence&.first(length)
    end
  end
end
