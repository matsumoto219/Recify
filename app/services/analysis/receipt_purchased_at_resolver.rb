module Analysis
  class ReceiptPurchasedAtResolver
    PURCHASE_ROLES = %w[transaction settlement issuance unknown].freeze
    ESTABLISHED_ROLES = %w[transaction settlement].freeze

    class << self
      def call(**attributes)
        resolve(**attributes)[:value]
      end

      def resolve(**attributes)
        new(**attributes).resolve
      end

      def fallback_snapshot(**attributes)
        resolve(**attributes)[:fallback]
      end
    end

    def initialize(ai_attrs:, candidates:, lines:, profile:, source_complete: true)
      @candidates = candidates
      @lines = lines
      @profile = profile
      @source_complete = source_complete
    end

    def resolve
      return resolution(nil, "missing") unless @profile

      evidence = source_evidence
      return resolution(nil, "uncertain") if evidence[:invalid] || !evidence[:complete]

      available = evidence[:candidates].select do |candidate|
        PURCHASE_ROLES.include?(candidate[:role]) && candidate[:association] != "invalid"
      end
      selected = purchase_events(available)
      return resolution(nil, "missing") if selected.empty?

      full = selected.select { |candidate| candidate[:precision] == "datetime" }
      dates = selected.filter_map { |candidate| candidate[:date] }.uniq
      clock_events = if full.present?
        selected.reject { |candidate| candidate[:precision] == "time_only" && candidate[:role] == "unknown" }
      else
        selected
      end
      times = clock_events.filter_map { |candidate| canonical_time(candidate[:time]) }.uniq
      return resolution(nil, "conflicted") if dates.size > 1

      if full.present?
        return resolution(date_value(dates.first), "conflicted", precision: "date_only") if times.size > 1

        candidate = full.first
        return resolution(
          datetime_value(candidate),
          "confirmed",
          candidate: full.one? ? candidate : nil,
          precision: "datetime"
        )
      end

      if dates.one?
        candidate = selected.find { |entry| entry[:date] == dates.first }
        associated_times = selected.filter_map do |entry|
          canonical_time(entry[:time]) if entry[:role] != "unknown" && entry[:association] == "exact"
        end.uniq
        state = if associated_times.size > 1
          "conflicted"
        elsif times.present?
          "uncertain"
        else
          "date_only"
        end
        return resolution(date_value(dates.first), state, candidate: candidate, precision: "date_only")
      end

      resolution(nil, "uncertain")
    end

    private

    def source_evidence
      if @candidates.key?(:purchased_at_evidence)
        return PurchasedAtEvidence.call(@candidates[:purchased_at_evidence]) || PurchasedAtEvidence.call({})
      end

      return PurchasedAtEvidence.call({}) unless @source_complete

      source_lines = Array(@lines)
      if source_lines.empty?
        source_lines = Array(@candidates[:purchased_at_candidates]) + Array(@candidates[:purchase_context_lines])
      end
      hint = @candidates[:purchased_at_text]
      if source_lines.empty?
        source_lines = [ hint ].compact
      elsif safe_legacy_date_hint?(hint, source_lines)
        source_lines = [ hint ] + source_lines
      end

      evidence = PurchasedAtEvidence.from_lines(lines: source_lines, profile: @profile)
      return evidence if evidence[:invalid] || evidence[:candidates].any? { |candidate| candidate[:date] }
      return evidence unless hint.is_a?(String) && hint.bytesize <= 128

      hinted = PurchasedAtEvidence.from_lines(lines: [ hint ], profile: @profile)
      dated = hinted[:candidates].select { |candidate| candidate[:date] }
      return evidence unless dated.one?
      if dated.first[:time]
        excluded = evidence[:candidates].any? do |candidate|
          !PURCHASE_ROLES.include?(candidate[:role]) &&
            canonical_time(candidate[:time]) == canonical_time(dated.first[:time])
        end
        return evidence if excluded
      end

      candidate = dated.first.merge(candidate_id: "datetime_legacy_0", source_path: "candidates.purchased_at_text")
        .except(:line_index, :label_path)
      PurchasedAtEvidence.call(evidence.merge(candidates: [ candidate ] + evidence[:candidates]))
    end

    def safe_legacy_date_hint?(hint, source_lines)
      return false unless hint.is_a?(String) && date_only_text?(hint)
      return false if source_lines.any? { |text| @profile.ocr_purchased_at_date_patterns.any? { |pattern| text.to_s.match?(pattern) } }

      source_lines.none? { |text| text.to_s.match?(@profile.analysis_purchase_time_exclusion_pattern) }
    end

    def purchase_events(candidates)
      established = candidates.select { |candidate| ESTABLISHED_ROLES.include?(candidate[:role]) }
      return established if established.present?

      issued = candidates.select { |candidate| candidate[:role] == "issuance" }
      issued.presence || candidates.select { |candidate| candidate[:role] == "unknown" }
    end

    def datetime_value(candidate)
      date = Date.iso8601(candidate[:date])
      hour, minute, second = candidate[:time].split(":").map(&:to_i)
      Time.zone.local(date.year, date.month, date.day, hour, minute, second || 0)
    end

    def date_value(text)
      return unless text

      date = Date.iso8601(text)
      Time.zone.local(date.year, date.month, date.day)
    end

    def canonical_time(value)
      return unless value

      value.length == 5 ? "#{value}:00" : value
    end

    def resolution(value, state, candidate: nil, precision: nil)
      precision ||= candidate&.fetch(:precision)
      reason = case state
      when "missing"
        "purchased_at_missing"
      when "uncertain"
        "purchased_at_uncertain"
      when "conflicted"
        "purchased_at_conflicted"
      end
      result = {
        value: value,
        state: state,
        precision: precision,
        role: candidate&.fetch(:role),
        candidate_id: candidate&.fetch(:candidate_id),
        reason_codes: [ reason ].compact
      }.compact
      result[:value] = value
      result[:fallback] = fallback_for(result)
      result
    end

    def fallback_for(result)
      value = result[:value]
      hint = @candidates[:purchased_at_text]
      if @candidates.key?(:purchased_at_evidence)
        return {
          applied: result[:state] == "confirmed",
          source: "ocr_datetime_evidence",
          result: value&.strftime("%Y-%m-%d %H:%M")
        }.compact
      end

      return { applied: false, source: "ocr_purchased_at_text" } if hint.present? && !date_only_text?(hint) && value

      if value && result[:precision] == "datetime" && date_only_text?(hint)
        detail = Array(@lines).filter_map { |text| time_expression_detail(text) }
          .find { |entry| entry[:time] == value.strftime("%H:%M") }
        return {
          applied: true,
          source: "ocr_time_candidate",
          date_text: hint,
          time_text: detail&.fetch(:raw_time_text),
          normalized_time: value.strftime("%H:%M"),
          ignored_prefix: detail&.fetch(:ignored_prefix),
          source_text: detail&.fetch(:source_text),
          result: value.strftime("%Y-%m-%d %H:%M")
        }.compact
      end

      if date_only_text?(hint)
        { applied: false, reason: "unique_time_candidate_missing", date_text: hint }
      else
        { applied: false, reason: "date_candidate_missing_or_not_date_only" }
      end
    end

    def date_only_text?(value)
      return false unless @profile && value.is_a?(String) && value.valid_encoding? && value.bytesize <= 128
      return false if time_expression_detail(value)

      @profile.analysis_purchased_at_date_only_patterns.any? { |pattern| value.match?(pattern) }
    end

    def time_expression_detail(text)
      return unless text.is_a?(String) && text.valid_encoding? && text.bytesize <= 500

      match = text.match(@profile.analysis_purchase_time_expression_pattern)
      return unless match

      raw_end = match.end(2)
      raw_time_text = text[match.begin(1)...raw_end]
      raw_time_text += "分" if text[raw_end] == "分"
      {
        time: "#{match[1].to_i.to_s.rjust(2, '0')}:#{match[2]}",
        raw_time_text: raw_time_text,
        ignored_prefix: text[0...match.begin(1)].strip.presence,
        source_text: text.strip
      }
    end
  end
end
