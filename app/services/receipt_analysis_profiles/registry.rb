module ReceiptAnalysisProfiles
  module Registry
    SUPPORTED_COUNTRY_CODES = {
      "JPN" => ReceiptAnalysisProfiles::Japan
    }.freeze

    class << self
      def default
        ReceiptAnalysisProfiles::Japan
      end

      def fetch(country_code)
        normalized = normalize_country_code(country_code)
        return default if normalized.blank?

        SUPPORTED_COUNTRY_CODES[normalized]
      end

      def supported?(country_code)
        fetch(country_code).present?
      end

      private

      def normalize_country_code(country_code)
        country_code.to_s.strip.upcase.presence
      end
    end
  end
end
