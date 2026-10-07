module Analysis
  class PurchasedAtEvidence
    SCHEMA_VERSION = "purchased_at_evidence_v1"
    MAX_CANDIDATES = 50
    MAX_BYTES = 32 * 1024
    MAX_LINES = 10_000
    MAX_SOURCE_BYTES = 1_048_576
    MAX_SPAN_INDEX = 10_000_000
    ENVELOPE_KEYS = %i[schema_version candidates complete truncated omitted_count invalid].freeze
    CANDIDATE_KEYS = %i[
      candidate_id date time precision role association source_path line_index page_index
      span string_index_type label_path date_path time_path
    ].freeze
    ROLES = %w[transaction settlement issuance service_start service_end duration reference unknown].freeze
    EXCLUDED_ROLES = %w[service_start service_end duration reference].freeze
    ASSOCIATIONS = %w[exact unlabeled invalid].freeze
    INDEX_TYPES = %w[utf16CodeUnit textElements].freeze
    PATH_PATTERN = /\A(?:lines\[\d{1,4}\]|pages\[\d{1,2}\]\.lines\[\d{1,4}\]|fields\.Transaction(?:Date|Time)|candidates\.purchased_at_text)\z/.freeze
    ID_PATTERN = /\Adatetime_(?:line_\d{1,4}|page_\d{1,2}_line_\d{1,4}|structured_\d|legacy_0)(?:_part_\d{1,2})?\z/.freeze
    DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/.freeze
    TIME_PATTERN = /\A(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?\z/.freeze

    def self.call(value, max_candidates: MAX_CANDIDATES)
      return if value.nil?

      new(max_candidates:).call(value)
    end

    def self.from_lines(lines:, profile:, line_sources: nil)
      PurchasedAtLineEvidenceBuilder.call(lines:, profile:, line_sources:)
    end

    def initialize(max_candidates:)
      @max_candidates = max_candidates
    end

    def call(value)
      envelope = bounded_hash(value, ENVELOPE_KEYS)
      return invalid unless envelope&.keys&.sort == ENVELOPE_KEYS.sort
      return invalid unless envelope[:schema_version] == SCHEMA_VERSION
      return invalid unless %i[complete truncated invalid].all? { |key| [ true, false ].include?(envelope[key]) }
      return invalid unless bounded_integer?(envelope[:omitted_count], MAX_LINES)
      return invalid if envelope[:omitted_count].positive? && !envelope[:truncated]
      return invalid unless max_candidates.is_a?(Integer) && max_candidates.between?(1, MAX_CANDIDATES)
      return invalid if envelope[:invalid]

      candidates = envelope[:candidates]
      return invalid unless candidates.is_a?(Array) && candidates.size <= MAX_CANDIDATES

      candidates = candidates.map { |candidate| normalize_candidate(candidate) }
      return invalid if candidates.any?(&:nil?)
      return invalid unless candidates.map { |candidate| candidate[:candidate_id] }.uniq.size == candidates.size

      ordered = candidates.reject { |candidate| EXCLUDED_ROLES.include?(candidate[:role]) } +
        candidates.select { |candidate| EXCLUDED_ROLES.include?(candidate[:role]) }
      retained_ids = ordered.first(max_candidates).map { |candidate| candidate[:candidate_id] }
      retained, omitted = candidates.partition { |candidate| retained_ids.include?(candidate[:candidate_id]) }
      omitted_count = envelope[:omitted_count] + omitted.size
      return invalid if omitted_count > MAX_LINES

      result = envelope.merge(
        candidates: retained,
        complete: envelope[:complete] && omitted.all? { |candidate| EXCLUDED_ROLES.include?(candidate[:role]) && candidate[:association] != "invalid" },
        truncated: envelope[:truncated] || omitted.any?,
        omitted_count:
      )
      return invalid if result.to_json.bytesize > MAX_BYTES

      deep_freeze(result)
    end

    private

    attr_reader :max_candidates

    def normalize_candidate(value)
      candidate = bounded_hash(value, CANDIDATE_KEYS)
      return unless candidate
      return unless candidate[:candidate_id].is_a?(String) && candidate[:candidate_id].bytesize <= 80 && candidate[:candidate_id].valid_encoding? && candidate[:candidate_id].ascii_only? && candidate[:candidate_id].match?(ID_PATTERN)
      return unless ROLES.include?(candidate[:role]) && ASSOCIATIONS.include?(candidate[:association])
      return unless valid_precision?(candidate)
      return unless %i[source_path label_path date_path time_path].all? { |key| !candidate.key?(key) || valid_path?(candidate[key]) }
      return unless valid_path?(candidate[:source_path])
      return if candidate.key?(:line_index) && !bounded_integer?(candidate[:line_index], MAX_LINES - 1)
      return if candidate.key?(:page_index) && !bounded_integer?(candidate[:page_index], 99)
      return unless valid_span?(candidate)

      candidate.transform_values { |child| child.is_a?(String) ? child.dup : child }
    end

    def valid_precision?(candidate)
      return false if candidate.key?(:date) && !valid_date?(candidate[:date])
      return false if candidate.key?(:time) && !(candidate[:time].is_a?(String) && [ 5, 8 ].include?(candidate[:time].bytesize) && candidate[:time].valid_encoding? && candidate[:time].ascii_only? && candidate[:time].match?(TIME_PATTERN))

      case candidate[:precision]
      when "datetime"
        candidate.key?(:date) && candidate.key?(:time)
      when "date_only"
        candidate.key?(:date) && !candidate.key?(:time)
      when "time_only"
        candidate.key?(:time) && !candidate.key?(:date)
      else
        false
      end
    end

    def valid_date?(value)
      return false unless value.is_a?(String) && value.bytesize == 10 && value.valid_encoding? && value.ascii_only? && value.match?(DATE_PATTERN)

      Date.iso8601(value).year.between?(1, 9999)
    rescue Date::Error
      false
    end

    def valid_span?(candidate)
      return !candidate.key?(:string_index_type) unless candidate.key?(:span)
      return false unless INDEX_TYPES.include?(candidate[:string_index_type])

      span = bounded_hash(candidate[:span], %i[offset length])
      return false unless span&.keys&.sort == %i[length offset]
      return false unless bounded_integer?(span[:offset], MAX_SPAN_INDEX)
      return false unless span[:length].is_a?(Integer) && span[:length].positive?
      return false if span[:length] > MAX_SPAN_INDEX - span[:offset]

      candidate[:span] = span
      true
    end

    def valid_path?(value)
      value.is_a?(String) && value.bytesize <= 128 && value.valid_encoding? && value.ascii_only? && value.match?(PATH_PATTERN)
    end

    def bounded_integer?(value, maximum)
      value.is_a?(Integer) && value.between?(0, maximum)
    end

    def bounded_hash(value, keys)
      return unless value.is_a?(Hash) && value.size <= keys.size
      return unless value.keys.all? { |key| keys.include?(key) || keys.any? { |allowed| key == allowed.to_s } }

      normalized = value.each_with_object({}) { |(key, child), result| result[key.to_sym] = child }
      normalized if normalized.size == value.size
    end

    def invalid
      deep_freeze({ schema_version: SCHEMA_VERSION, candidates: [], complete: false, truncated: false, omitted_count: 0, invalid: true })
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each_value { |child| deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
  end
end
