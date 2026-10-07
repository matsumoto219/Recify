module Analysis
  class PurchasedAtLineEvidenceBuilder
    CONTROL_PATTERN = /[\u0000-\u001F\u007F]/.freeze
    CLOCK_TOKEN_PATTERN = /(?<![\p{L}\d:：])\d{1,2}\s*[:：]\s*\d{2,}(?:\s*[:：]\s*\d+)*(?![\d:：])/.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(lines:, profile:, line_sources: nil)
      @lines = lines
      @profile = profile
      @line_sources = line_sources
    end

    def call
      return PurchasedAtEvidence.call({}) unless valid_lines?

      entries = lines.each_with_index.map { |text, index| entry(text, index) }
      candidates = entries.filter_map { |entry| candidate(entry, entries) }
      candidates = combine_partial_candidates(candidates, entries)
      complete = entries.none? { |entry| entry[:invalid] } && candidates.none? { |candidate| candidate[:association] == "invalid" }
      omitted = candidates.drop(PurchasedAtEvidence::MAX_CANDIDATES)
      PurchasedAtEvidence.call(
        {
          schema_version: PurchasedAtEvidence::SCHEMA_VERSION,
          candidates: candidates.first(PurchasedAtEvidence::MAX_CANDIDATES),
          complete: complete && omitted.none?, truncated: omitted.any?, omitted_count: omitted.size, invalid: false
        }
      )
    end

    private

    attr_reader :lines, :profile, :line_sources

    def valid_lines?
      lines.is_a?(Array) && lines.size <= PurchasedAtEvidence::MAX_LINES &&
        lines.all? { |line| line.is_a?(String) && line.valid_encoding? && (line.encoding == Encoding::UTF_8 || line.ascii_only?) && line.bytesize <= 10_000 && !line.match?(CONTROL_PATTERN) } &&
        lines.sum(&:bytesize) <= PurchasedAtEvidence::MAX_SOURCE_BYTES &&
        (line_sources.nil? || (line_sources.is_a?(Array) && line_sources.size == lines.size && line_sources.all?(Hash)))
    end

    def entry(text, index)
      date_matches = profile.ocr_purchased_at_date_patterns.flat_map { |pattern| text.to_enum(:scan, pattern).map { Regexp.last_match } }
        .uniq { |match| [ match.begin(0), match.end(0) ] }
      time_matches = text.to_enum(:scan, profile.ocr_purchased_at_time_pattern).map { Regexp.last_match }
      clock_tokens = text.to_enum(:scan, CLOCK_TOKEN_PATTERN).map { Regexp.last_match }
      roles = profile.ocr_purchased_at_role_patterns.filter_map { |role, pattern| role if text.match?(pattern) }
      role = if roles.include?("reference")
        "reference"
      elsif roles.include?("duration")
        "duration"
      elsif roles.one?
        roles.first
      else
        "unknown"
      end
      date = canonical_date(date_matches.first&.to_s)
      time = canonical_time(time_matches.first)
      excluded = PurchasedAtEvidence::EXCLUDED_ROLES.include?(role)
      malformed_clock = clock_tokens.any? do |token|
        temporal_context = date_matches.any? || %w[transaction settlement issuance].include?(role) || token.to_s == text.strip
        temporal_context && time_matches.none? { |match| token.begin(0) == match.begin(0) && token.end(0) <= match.end(0) }
      end
      invalid = (!excluded && (date_matches.size > 1 || time_matches.size > 1 ||
        (date_matches.any? && date.nil?) || (time_matches.any? && time.nil?) ||
        malformed_clock)) ||
        (roles.size > 1 && role == "unknown")
      invalid ||= line_sources && source_for(index)[:association] == "invalid"
      { text:, index:, date:, time:, role:, label: roles.any?, invalid: }
    end

    def canonical_date(value)
      return unless value

      parts = value.scan(/\d+/)
      return unless parts.size == 3

      year, month, day = if parts[0].length == 4
        parts
      elsif parts[2].length == 4
        [ parts[2], parts[0], parts[1] ]
      else
        return
      end
      Date.new(year.to_i, month.to_i, day.to_i).iso8601
    rescue Date::Error
      nil
    end

    def canonical_time(match)
      return unless match

      hour, minute, second = match.captures.first(3)
      return unless hour && minute
      return if hour.to_i > 23 || minute.to_i > 59 || (second && second.to_i > 59)

      [ hour, minute, second ].compact.map { |value| value.rjust(2, "0") }.join(":")
    end

    def candidate(entry, entries)
      return unless entry[:date] || entry[:time]

      source = source_for(entry[:index])
      role = entry[:role]
      label_path = source[:label_path]
      association = entry[:invalid] ? "invalid" : source.fetch(:association, "unlabeled")
      if entry[:label]
        association = "exact" unless association == "invalid"
      elsif source[:label_role]
        role = source[:label_role]
      elsif line_sources.nil?
        preceding = entries[entry[:index] - 1] if entry[:index].positive?
        if preceding && preceding[:label] && !preceding[:date] && !preceding[:time] && !preceding[:invalid]
          previous_label = entries[entry[:index] - 2] if entry[:index] >= 2
          if previous_label && previous_label[:label] && !previous_label[:date] && !previous_label[:time]
            association = "invalid"
          else
            role = preceding[:role]
            association = "exact"
            label_path = "lines[#{preceding[:index]}]"
          end
        end
      end

      {
        candidate_id: source[:candidate_id], source_path: source[:source_path], line_index: entry[:index],
        role:, association:, date: entry[:date], time: entry[:time], precision: precision(entry[:date], entry[:time]),
        label_path:
      }.compact.merge(source.slice(:page_index, :span, :string_index_type))
    end

    def source_for(index)
      return line_sources[index] if line_sources

      { candidate_id: "datetime_line_#{index}", source_path: "lines[#{index}]" }
    end

    def combine_partial_candidates(candidates, entries)
      candidates.each_with_index.filter_map do |candidate, index|
        next if candidate[:consumed]

        following = candidates[index + 1]
        if combinable?(candidate, following, entries)
          candidate = candidate.merge(
            time: following[:time], precision: "datetime", time_path: following[:source_path],
            association: candidate[:association] == "exact" ? "exact" : "unlabeled"
          )
          following[:consumed] = true
        end
        candidate.except(:consumed)
      end
    end

    def combinable?(candidate, following, entries)
      return false unless candidate[:precision] == "date_only" && following&.dig(:precision) == "time_only"
      return false if candidate[:association] == "invalid" || following[:association] == "invalid"
      return false unless candidate[:page_index] == following[:page_index]
      gap = following[:line_index] - candidate[:line_index]
      return false unless gap == 1 || (gap == 2 && safe_bridge?(candidate, following, entries))
      return false if line_sources && source_for(candidate[:line_index])[:join_next] == false
      return false if line_sources && gap == 2 && source_for(candidate[:line_index] + 1)[:join_next] == false
      return false unless following[:role] == "unknown" || following[:role] == candidate[:role]
      if following[:label_path] && following[:label_path] != candidate[:label_path]
        return false unless gap == 2 && explicit_time_label?(candidate, following, entries)
      end

      time_line = entries[following[:line_index]][:text]
      time_line.gsub(profile.ocr_purchased_at_time_pattern, "").strip.empty? ||
        time_line.match?(profile.ocr_purchased_at_time_continuation_pattern)
    end

    def safe_bridge?(candidate, following, entries)
      bridge = entries[candidate[:line_index] + 1]
      return false if bridge[:date] || bridge[:time] || bridge[:invalid]
      return explicit_time_label?(candidate, following, entries) if bridge[:label]

      bridge[:text].match?(profile.ocr_purchased_at_bridge_line_pattern)
    end

    def explicit_time_label?(candidate, following, entries)
      label = entries[candidate[:line_index] + 1]
      %w[transaction settlement issuance].include?(candidate[:role]) &&
        candidate[:association] == "exact" && following[:association] == "exact" &&
        candidate[:role] == following[:role] && label[:role] == candidate[:role]
    end

    def precision(date, time)
      return "datetime" if date && time

      date ? "date_only" : "time_only"
    end
  end
end
