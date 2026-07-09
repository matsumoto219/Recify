module Analysis
  class MoneyTokenClassifier
    CURRENCY_EVIDENCE_PATTERN = /[¥￥$€£]|円/.freeze
    SIGN_EVIDENCE_PATTERN = /[▲△\-−]/.freeze
    PERCENT_SUFFIX_PATTERN = /\A\s*[%％]/.freeze
    NO_MATCH_PATTERN = /(?!)/.freeze

    class << self
      def call(...)
        new(...).call
      end

      def money_matches(text:, money_pattern:, profile:, allow_bare_money:)
        call(text:, money_pattern:, profile:).select do |token|
          token[:kind] == :money || (allow_bare_money && token[:kind] == :bare_number)
        end
      end
    end

    def initialize(text:, money_pattern:, profile:)
      @text = text.to_s
      @money_pattern = money_pattern
      @profile = profile
    end

    def call
      text.to_enum(:scan, money_pattern).filter_map do
        match = Regexp.last_match
        amount = ReceiptAmountService.parse_amount_or_nil(match[0])&.to_i&.abs
        next unless amount&.positive?

        {
          raw_text: match[0],
          normalized_text: match[0].unicode_normalize(:nfkc),
          amount: amount,
          kind: token_kind(match),
          span_start: match.begin(0),
          span_end: match.end(0),
          money_evidence: money_evidence?(match)
        }
      end
    end

    private

    attr_reader :text, :money_pattern, :profile

    def token_kind(match)
      return :percent if suffix_after(match).match?(PERCENT_SUFFIX_PATTERN)
      return :quantity if suffix_after(match).match?(anchored_pattern(:adjustment_quantity_unit_pattern))
      return :point if suffix_after(match).match?(anchored_pattern(:adjustment_point_unit_pattern))
      return :id_like if id_like_context? && !currency_evidence?(match)
      return :money if money_evidence?(match)

      :bare_number
    end

    def suffix_after(match)
      text[match.end(0)..].to_s
    end

    def anchored_pattern(name)
      /\A\s*(?:#{profile_pattern(name)})/
    end

    def id_like_context?
      text.match?(profile_pattern(:adjustment_id_like_context_pattern))
    end

    def money_evidence?(match)
      currency_evidence?(match) || signed_evidence?(match)
    end

    def currency_evidence?(match)
      match[0].match?(CURRENCY_EVIDENCE_PATTERN) || suffix_after(match).lstrip.start_with?("円")
    end

    def signed_evidence?(match)
      match[0].match?(SIGN_EVIDENCE_PATTERN)
    end

    def profile_pattern(name)
      return NO_MATCH_PATTERN unless profile.respond_to?(name)

      profile.public_send(name)
    end
  end
end
