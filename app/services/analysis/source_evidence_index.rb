module Analysis
  class SourceEvidenceIndex
    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(lines:, money_pattern:, profile:)
      @lines = Array(lines)
      @money_pattern = money_pattern
      @profile = profile
    end

    def call
      lines.each_with_index.map do |line, line_index|
        source_text = line.to_s

        {
          line_index: line_index,
          source_text: source_text,
          normalized_text: source_text.unicode_normalize(:nfkc),
          tokens: MoneyTokenClassifier.call(
            text: source_text,
            money_pattern: money_pattern,
            profile: profile
          )
        }
      end
    end

    private

    attr_reader :lines, :money_pattern, :profile
  end
end
