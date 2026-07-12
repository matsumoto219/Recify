module Analysis
  class ReceiptPurchasedAtResolver
    def self.call(ai_attrs:, candidates:, lines:, profile:)
      new(ai_attrs:, candidates:, lines:, profile:).call
    end

    def self.fallback_snapshot(ai_attrs:, candidates:, lines:, profile:)
      new(ai_attrs:, candidates:, lines:, profile:).fallback_snapshot
    end

    def initialize(ai_attrs:, candidates:, lines:, profile:)
      @ai_attrs = ai_attrs
      @candidates = candidates
      @lines = lines
      @profile = profile
    end

    def call
      explicit_ai_value = parse(@ai_attrs[:purchased_at])
      return explicit_ai_value if explicit_ai_value.present?

      ai_text = @ai_attrs[:purchased_at_text].presence
      parsed_ai_text = parse(ai_text)
      return parsed_ai_text if parsed_ai_text.present? && !date_only_text?(ai_text)

      candidate_text = @candidates[:purchased_at_text].presence
      parsed_candidate_text = parse(candidate_text)
      return parsed_candidate_text if parsed_candidate_text.present? && !date_only_text?(candidate_text)

      date_text = ai_text.presence || candidate_text
      parsed_date = parsed_ai_text || parsed_candidate_text
      return parsed_date unless parsed_date.present? && date_only_text?(date_text)

      time_candidate = unique_time_candidate_detail(time_candidate_values)
      return parsed_date if time_candidate.blank?

      parse("#{parsed_date.strftime('%Y-%m-%d')} #{time_candidate[:time]}") || parsed_date
    end

    def fallback_snapshot
      explicit_ai_value = parse(@ai_attrs[:purchased_at])
      return { applied: false, source: "ai_purchased_at" } if explicit_ai_value.present?

      ai_text = @ai_attrs[:purchased_at_text].presence
      parsed_ai_text = parse(ai_text)
      return { applied: false, source: "ai_purchased_at_text" } if parsed_ai_text.present? && !date_only_text?(ai_text)

      candidate_text = @candidates[:purchased_at_text].presence
      parsed_candidate_text = parse(candidate_text)
      if parsed_candidate_text.present? && !date_only_text?(candidate_text)
        return { applied: false, source: "ocr_purchased_at_text" }
      end

      date_text = ai_text.presence || candidate_text
      parsed_date = parsed_ai_text || parsed_candidate_text
      unless parsed_date.present? && date_only_text?(date_text)
        return {
          applied: false,
          reason: "date_candidate_missing_or_not_date_only"
        }
      end

      time_candidate = unique_time_candidate_detail(time_candidate_values)
      if time_candidate.blank?
        return {
          applied: false,
          reason: "unique_time_candidate_missing",
          date_text: date_text
        }
      end

      result = parse("#{parsed_date.strftime('%Y-%m-%d')} #{time_candidate[:time]}")
      return { applied: false, reason: "combined_datetime_parse_failed", date_text: date_text } if result.blank?

      {
        applied: true,
        source: "ocr_time_candidate",
        date_text: date_text,
        time_text: time_candidate[:raw_time_text],
        normalized_time: time_candidate[:time],
        ignored_prefix: time_candidate[:ignored_prefix],
        source_text: time_candidate[:source_text],
        result: result.strftime("%Y-%m-%d %H:%M")
      }.compact
    end

    private

    def parse(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def date_only_text?(value)
      text = value.to_s.strip
      return false if text.blank?
      return false if time_expression(text).present?

      @profile.analysis_purchased_at_date_only_patterns.any? { |pattern| text.match?(pattern) }
    end

    def time_candidate_values
      Array(@candidates[:purchased_at_candidates]) +
        Array(@candidates[:purchase_context_lines]) +
        Array(@lines)
    end

    def unique_time_candidate_detail(values)
      candidates = Array(values).filter_map do |value|
        text = value.to_s.strip
        next if text.blank?
        next unless purchase_time_context_line?(text)

        time_expression_detail(text)
      end.uniq { |candidate| candidate[:time] }

      candidates.one? ? candidates.first : nil
    end

    def purchase_time_context_line?(text)
      return false if text.match?(@profile.analysis_purchase_time_exclusion_pattern)

      time_expression(text).present?
    end

    def time_expression(text)
      time_expression_detail(text)&.fetch(:time)
    end

    def time_expression_detail(text)
      match = text.to_s.match(@profile.analysis_purchase_time_expression_pattern)
      return nil unless match

      raw_end = match.end(2)
      raw_time_text = text[match.begin(1)...raw_end].to_s
      raw_time_text += "分" if text[raw_end] == "分"

      {
        time: "#{match[1].to_i.to_s.rjust(2, '0')}:#{match[2]}",
        raw_time_text: raw_time_text,
        ignored_prefix: text[0...match.begin(1)].to_s.strip.presence,
        source_text: text.to_s.strip
      }
    end
  end
end
