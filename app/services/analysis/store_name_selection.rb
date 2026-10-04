module Analysis
  class StoreNameSelection
    DECISIONS = %w[select ambiguous reject invalid].freeze
    KEYS = %w[decision option_id options_checksum].freeze
    OPTION_ID_PATTERN = /\Astore_option_[0-9a-f]{32}\z/
    CHECKSUM_PATTERN = /\A[0-9a-f]{64}\z/

    class << self
      def call(value, options: nil)
        return if value.nil? && options.nil?

        selection = normalize(value)
        return selection unless options.is_a?(Hash)

        bind(selection, options)
      end

      private

      def normalize(value)
        return invalid unless value.is_a?(Hash) && value.size <= KEYS.size
        return invalid unless value.keys.all? { |key| (key.is_a?(String) || key.is_a?(Symbol)) && KEYS.include?(key.to_s) }

        data = value.symbolize_keys
        return invalid unless data.size == value.size
        return invalid unless DECISIONS.include?(data[:decision])
        return invalid if data[:options_checksum] && !valid_checksum?(data[:options_checksum])
        return invalid unless valid_option?(data)

        {
          decision: data[:decision],
          option_id: data[:option_id],
          options_checksum: data[:options_checksum]
        }.compact
      end

      def valid_option?(data)
        return data[:option_id].nil? unless data[:decision] == "select"

        id = data[:option_id]
        id.is_a?(String) && id.valid_encoding? && id.bytesize <= 100 && OPTION_ID_PATTERN.match?(id)
      end

      def valid_checksum?(value)
        value.is_a?(String) && value.valid_encoding? && value.bytesize == 64 && CHECKSUM_PATTERN.match?(value)
      end

      def bind(selection, options)
        checksum = options[:checksum] || options["checksum"]
        return invalid unless valid_checksum?(checksum)
        if selection[:options_checksum] && selection[:options_checksum] != checksum
          return invalid.merge(options_checksum: checksum)
        end

        entries = options[:options] || options["options"]
        if selection[:decision] == "select" && !unique_option?(entries, selection[:option_id])
          return invalid.merge(options_checksum: checksum)
        end

        selection.merge(options_checksum: checksum)
      end

      def unique_option?(entries, option_id)
        return false unless entries.is_a?(Array) && entries.size <= StoreNameEvidence::MAX_CANDIDATES

        entries.count { |entry| entry.is_a?(Hash) && (entry[:option_id] || entry["option_id"]) == option_id } == 1
      end

      def invalid
        { decision: "invalid" }
      end
    end
  end
end
