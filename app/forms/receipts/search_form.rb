module Receipts
  class SearchForm
    DATE_PATTERN = "\\d{4}[\\/-]\\d{2}[\\/-]\\d{2}".freeze

    Result = Struct.new(:valid, :error_code, keyword_init: true) do
      def valid?
        valid
      end
    end

    def self.call(query)
      new(query).call
    end

    def initialize(query)
      @query = query.to_s
    end

    def call
      invalid_date_token = tokens.find { |token| invalid_complete_date_operator?(token) }

      Result.new(
        valid: invalid_date_token.blank?,
        error_code: invalid_date_token.present? ? "invalid_search_query" : nil
      )
    end

    private

    attr_reader :query

    def tokens
      query.strip.split(/\s+/).first(5)
    end

    def invalid_complete_date_operator?(token)
      stripped = token.strip

      case stripped
      when /\Adate(?:>=|<=)(#{DATE_PATTERN})\z/
        invalid_date?($1)
      when /\Adate:(#{DATE_PATTERN})\.\.(#{DATE_PATTERN})\z/
        invalid_date?($1) || invalid_date?($2)
      else
        false
      end
    end

    def invalid_date?(date_text)
      Date.parse(date_text)
      false
    rescue ArgumentError
      true
    end
  end
end
