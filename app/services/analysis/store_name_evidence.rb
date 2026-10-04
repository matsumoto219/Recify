module Analysis
  class StoreNameEvidence
    SCHEMA_VERSION = "store_name_evidence_v1"
    MAX_CANDIDATES = 100
    MAX_TEXT_BYTES = 500
    MAX_TEXT_LENGTH = 255
    MAX_LINE_INDEX = 9_999
    MAX_PAGE_INDEX = 99
    MAX_SPAN_INDEX = 10_000_000
    MAX_BYTES = 128 * 1024
    ENVELOPE_KEYS = %i[schema_version candidates truncated invalid].freeze
    CANDIDATE_KEYS = %i[
      candidate_id text source source_path line_index page_index provider_line_index
      confidence span_state span string_index_type
    ].freeze
    SPAN_KEYS = %i[offset length].freeze
    INDEX_TYPES = %w[utf16CodeUnit textElements].freeze
    MERCHANT_PATHS = %w[documents[0].fields.MerchantName fields.MerchantName].freeze
    SPAN_STATES = %w[missing exact invalid].freeze
    CONTROL_PATTERN = /[\u0000-\u001F\u007F]/.freeze

    def self.call(value, max_candidates: MAX_CANDIDATES)
      return if value.nil?

      new(max_candidates:).call(value)
    end

    def initialize(max_candidates:)
      @max_candidates = max_candidates
    end

    def call(value)
      envelope = bounded_hash(value, ENVELOPE_KEYS)
      return invalid unless envelope&.keys&.sort == ENVELOPE_KEYS.sort
      return invalid unless envelope[:schema_version] == SCHEMA_VERSION
      return invalid unless [ true, false ].include?(envelope[:truncated]) && envelope[:invalid] == false
      return invalid unless max_candidates.is_a?(Integer) && max_candidates.between?(1, MAX_CANDIDATES)

      candidates = envelope[:candidates]
      return invalid unless candidates.is_a?(Array) && candidates.size <= MAX_CANDIDATES

      candidates = candidates.map { |candidate| normalize_candidate(candidate) }
      return invalid if candidates.any?(&:nil?)
      return invalid unless candidates.map { |candidate| candidate[:candidate_id] }.uniq.size == candidates.size

      result = {
        schema_version: SCHEMA_VERSION,
        candidates: candidates.first(max_candidates),
        truncated: envelope[:truncated] || candidates.size > max_candidates,
        invalid: false
      }
      return invalid if result.to_json.bytesize > MAX_BYTES

      deep_freeze(result)
    end

    private

    attr_reader :max_candidates

    def normalize_candidate(value)
      candidate = bounded_hash(value, CANDIDATE_KEYS)
      return unless candidate
      return unless safe_text?(candidate[:text])
      return unless SPAN_STATES.include?(candidate[:span_state])
      return unless valid_identity?(candidate)
      return unless valid_confidence?(candidate)
      return unless valid_span?(candidate)

      candidate.transform_values { |child| child.is_a?(String) ? child.dup : child }
    end

    def valid_identity?(candidate)
      line = candidate[:line_index]
      return false if candidate.key?(:line_index) && !bounded_index?(line, MAX_LINE_INDEX)

      page = candidate[:page_index]
      provider_line = candidate[:provider_line_index]
      if candidate.key?(:page_index) || candidate.key?(:provider_line_index)
        return false unless bounded_index?(page, MAX_PAGE_INDEX) && bounded_index?(provider_line, MAX_LINE_INDEX)
      end

      case candidate[:source]
      when "merchant_name"
        candidate[:candidate_id] == "merchant_name" &&
          MERCHANT_PATHS.include?(candidate[:source_path])
      when "line"
        return false unless bounded_index?(line, MAX_LINE_INDEX)

        if page
          candidate[:candidate_id] == "page_#{page}_line_#{provider_line}" &&
            candidate[:source_path] == "pages[#{page}].lines[#{provider_line}]"
        else
          candidate[:candidate_id] == "line_#{line}" && candidate[:source_path] == "lines[#{line}]"
        end
      else
        false
      end
    end

    def valid_confidence?(candidate)
      return true unless candidate.key?(:confidence)
      return false unless candidate[:source] == "merchant_name"

      value = candidate[:confidence]
      (value.is_a?(Integer) || value.is_a?(Float)) && value.finite? && value.between?(0, 1)
    end

    def valid_span?(candidate)
      unless candidate[:span_state] == "exact"
        return !candidate.key?(:span) && !candidate.key?(:string_index_type)
      end
      return false unless INDEX_TYPES.include?(candidate[:string_index_type])

      span = bounded_hash(candidate[:span], SPAN_KEYS)
      return false unless span&.keys&.sort == SPAN_KEYS.sort
      return false unless bounded_index?(span[:offset], MAX_SPAN_INDEX)
      return false unless span[:length].is_a?(Integer) && span[:length].positive?
      return false if span[:length] > MAX_SPAN_INDEX - span[:offset]

      candidate[:span] = span
      true
    end

    def bounded_index?(value, maximum)
      value.is_a?(Integer) && value.between?(0, maximum)
    end

    def safe_text?(value)
      value.is_a?(String) && value.valid_encoding? &&
        (value.encoding == Encoding::UTF_8 || value.ascii_only?) &&
        value.bytesize.between?(1, MAX_TEXT_BYTES) && value.length <= MAX_TEXT_LENGTH &&
        !value.match?(CONTROL_PATTERN) && !value.strip.empty?
    end

    def bounded_hash(value, keys)
      return unless value.is_a?(Hash) && value.size <= keys.size
      return unless value.keys.all? { |key| keys.include?(key) || keys.any? { |allowed| key == allowed.to_s } }

      normalized = value.each_with_object({}) { |(key, child), result| result[key.to_sym] = child }
      normalized if normalized.size == value.size
    end

    def invalid
      deep_freeze({ schema_version: SCHEMA_VERSION, candidates: [], truncated: false, invalid: true })
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
