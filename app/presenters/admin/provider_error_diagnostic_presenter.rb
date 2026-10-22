module Admin
  class ProviderErrorDiagnosticPresenter
    FIELDS = %i[code type param target reason message_safe].freeze

    def initialize(detail)
      @diagnostic = ExternalServices.sanitize_error_detail(detail)&.dig(:diagnostic)
    end

    def recorded?
      @diagnostic.present?
    end

    def notice
      I18n.t("admin.provider_error_diagnostic.not_recorded") unless recorded?
    end

    def nodes
      return [] unless recorded?

      @diagnostic[:nodes].map do |node|
        {
          path: node[:path],
          fields: FIELDS.filter_map do |field|
            [ I18n.t("admin.provider_error_diagnostic.fields.#{field}"), node[field] ] if node[field].present?
          end
        }
      end
    end

    def omissions
      return [] unless recorded?

      @diagnostic[:omissions].map do |entry|
        {
          path: entry[:path],
          reason: I18n.t("admin.provider_error_diagnostic.omission_reasons.#{entry[:reason]}")
        }
      end
    end

    def local_issue
      issue = @diagnostic&.dig(:local_issue)
      I18n.t("admin.provider_error_diagnostic.local_issues.#{issue}") if issue
    end
  end
end
