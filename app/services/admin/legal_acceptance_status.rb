module Admin
  class LegalAcceptanceStatus
    DOCUMENT_TYPES = %w[terms privacy].freeze

    class << self
      def call(user_id:, locale: I18n.locale)
        new(user_id: user_id, locale: locale).call
      end
    end

    def initialize(user_id:, locale:)
      @user_id = user_id
      @locale = locale.to_s
    end

    def call
      return empty_result if user.blank?

      records = DOCUMENT_TYPES.map { |document_type| record_for(document_type) }

      {
        locale: locale,
        records: records,
        reconsent_required: records.any? { |record| record[:reconsent_required] }
      }
    end

    private

    attr_reader :user_id, :locale

    def user
      @user ||= User.includes(legal_acceptances: :legal_document).find_by(id: user_id)
    end

    def current_documents
      @current_documents ||= LegalDocument.published.current
                                          .where(locale: locale, document_type: DOCUMENT_TYPES)
                                          .index_by(&:document_type)
    end

    def acceptances_by_type
      @acceptances_by_type ||= user.legal_acceptances
                                   .select { |acceptance| acceptance.locale == locale && DOCUMENT_TYPES.include?(acceptance.document_type) }
                                   .group_by(&:document_type)
    end

    def record_for(document_type)
      current_document = current_documents[document_type]
      acceptances = Array(acceptances_by_type[document_type])
      latest_acceptance = latest_acceptance(acceptances)
      current_acceptance = current_acceptance(acceptances, current_document)
      status = status_for(acceptances: acceptances, current_acceptance: current_acceptance)

      {
        document_type: document_type,
        current_version: current_document&.version,
        latest_accepted_version: latest_acceptance&.version,
        latest_accepted_at: latest_acceptance&.accepted_at,
        accepted_context: latest_acceptance&.acceptance_context,
        accepted_locale: latest_acceptance&.locale,
        current_version_accepted: current_acceptance.present?,
        reconsent_required: reconsent_required?(current_document, current_acceptance),
        missing: acceptances.empty?,
        status: status
      }
    end

    def latest_acceptance(acceptances)
      acceptances.max_by { |acceptance| [ acceptance.accepted_at || Time.zone.at(0), acceptance.id.to_i ] }
    end

    def current_acceptance(acceptances, current_document)
      return if current_document.blank?

      acceptances.find { |acceptance| acceptance.legal_document_id == current_document.id }
    end

    def status_for(acceptances:, current_acceptance:)
      return "missing" if acceptances.empty?
      return "current_accepted" if current_acceptance.present?

      "outdated"
    end

    def reconsent_required?(current_document, current_acceptance)
      current_document&.reconsent_required? && current_acceptance.blank?
    end

    def empty_result
      {
        locale: locale,
        records: [],
        reconsent_required: false
      }
    end
  end
end
