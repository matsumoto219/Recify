module Analysis
  class StoreNameLayout
    SCOPE = "provider_line"
    COORDINATE_SCALE = 10_000
    MAX_BYTES = 32 * 1024
    MAX_ID_BYTES = 48
    ENVELOPE_KEYS = %i[scope coordinate_scale entries].freeze
    ENTRY_KEYS = %i[candidate_id page_index provider_line_index line_span bounds].freeze
    SPAN_KEYS = %i[offset length].freeze
    BOUNDS_KEYS = %i[left top width height].freeze

    def self.call(value, evidence:)
      return if value.nil?

      new(evidence:).call(value)
    end

    def initialize(evidence:)
      @evidence = StoreNameEvidence.call(evidence)
    end

    def call(value)
      return unless evidence && !evidence[:invalid]

      envelope = bounded_hash(value, ENVELOPE_KEYS)
      return unless envelope&.keys&.sort == ENVELOPE_KEYS.sort
      return unless envelope[:scope] == SCOPE && envelope[:coordinate_scale].is_a?(Integer) &&
        envelope[:coordinate_scale] == COORDINATE_SCALE

      entries = envelope[:entries]
      return unless entries.is_a?(Array) && entries.size <= StoreNameEvidence::MAX_CANDIDATES
      return unless entries.all? { |entry| known_entry_fields?(entry) }

      entries = entries.filter_map { |entry| bounded_hash(entry, ENTRY_KEYS) }
      identities = entries.filter_map { |entry| entry[:candidate_id] if bounded_identity?(entry[:candidate_id]) }
      return unless identities.uniq.size == identities.size

      candidates = evidence[:candidates].index_by { |candidate| candidate[:candidate_id] }
      entries = entries.filter_map { |entry| normalize_entry(entry, candidates) }
      return if entries.empty?

      result = { scope: SCOPE.dup, coordinate_scale: COORDINATE_SCALE, entries: }
      return if result.to_json.bytesize > MAX_BYTES

      deep_freeze(result)
    end

    private

    attr_reader :evidence

    def normalize_entry(entry, candidates)
      return unless bounded_identity?(entry[:candidate_id])

      candidate = candidates[entry[:candidate_id]]
      return unless candidate && candidate[:span_state] == "exact"
      return unless candidate[:page_index].is_a?(Integer) && candidate[:provider_line_index].is_a?(Integer)
      return unless entry[:page_index].is_a?(Integer) && entry[:provider_line_index].is_a?(Integer)
      return unless entry[:page_index] == candidate[:page_index] &&
        entry[:provider_line_index] == candidate[:provider_line_index]

      span = bounded_hash(entry[:line_span], SPAN_KEYS)
      bounds = bounded_hash(entry[:bounds], BOUNDS_KEYS)
      return unless valid_span?(span, candidate[:span]) && valid_bounds?(bounds)

      {
        candidate_id: entry[:candidate_id].dup,
        page_index: entry[:page_index], provider_line_index: entry[:provider_line_index],
        line_span: span, bounds:
      }
    end

    def valid_span?(span, candidate_span)
      return false unless span&.keys&.sort == SPAN_KEYS.sort

      offset = span[:offset]
      length = span[:length]
      maximum = StoreNameEvidence::MAX_SPAN_INDEX
      offset.is_a?(Integer) && offset.between?(0, maximum) &&
        length.is_a?(Integer) && length.positive? && length <= maximum - offset &&
        offset <= candidate_span[:offset] &&
        candidate_span[:offset] + candidate_span[:length] <= offset + length
    end

    def valid_bounds?(bounds)
      return false unless bounds&.keys&.sort == BOUNDS_KEYS.sort
      return false unless bounds.values.all? { |value| value.is_a?(Integer) && value.between?(0, COORDINATE_SCALE) }

      bounds[:width].positive? && bounds[:height].positive? &&
        bounds[:left] + bounds[:width] <= COORDINATE_SCALE &&
        bounds[:top] + bounds[:height] <= COORDINATE_SCALE
    end

    def bounded_identity?(value)
      value.is_a?(String) && value.valid_encoding? && value.ascii_only? &&
        value.bytesize.between?(1, MAX_ID_BYTES) && value.match?(/\A[a-z0-9_]+\z/)
    end

    def known_entry_fields?(value)
      return true unless value.is_a?(Hash)

      entry = bounded_hash(value, ENTRY_KEYS)
      return false unless entry

      [ [ entry[:line_span], SPAN_KEYS ], [ entry[:bounds], BOUNDS_KEYS ] ].all? do |child, keys|
        !child.is_a?(Hash) || bounded_hash(child, keys)
      end
    end

    def bounded_hash(value, keys)
      return unless value.is_a?(Hash) && value.size <= keys.size
      return unless value.keys.all? { |key| keys.include?(key) || keys.any? { |allowed| key == allowed.to_s } }

      normalized = value.each_with_object({}) { |(key, child), result| result[key.to_sym] = child }
      normalized if normalized.size == value.size
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
