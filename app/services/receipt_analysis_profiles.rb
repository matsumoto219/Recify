module ReceiptAnalysisProfiles
  DEFAULT_COUNTRY_CODE = "JPN"

  class << self
    def default
      Registry.default
    end

    def fetch(country_code)
      Registry.fetch(country_code)
    end

    alias for_country fetch
  end
end
