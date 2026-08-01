# frozen_string_literal: true

class Receipts::IdentifierInput
  # Canonical IDs are ASCII; 32 matches the public_id model/column maximum.
  MAX_INPUT_BYTES = 32
  private_constant :MAX_INPUT_BYTES

  Result = Data.define(:kind, :value, :malformed) do
    def malformed?
      malformed
    end
  end

  class << self
    def call(value)
      return result unless value.is_a?(String)
      return result(malformed: true) if value.bytesize > MAX_INPUT_BYTES
      return result(malformed: true) if value.b.include?("\0".b)
      return result(malformed: true) unless value.valid_encoding?
      return result unless value.encoding.ascii_compatible?

      normalized = value.strip
      return result if normalized.empty?

      if normalized.ascii_only?
        display_id = normalized.upcase(:ascii)
        return result(kind: :display_id, value: display_id) if Receipt::DISPLAY_ID_FORMAT.match?(display_id)
        return result(kind: :public_id, value: normalized) if Receipt::PUBLIC_ID_FORMAT.match?(normalized)
      end

      result(malformed: identifier_like?(normalized))
    end

    private

    def result(kind: nil, value: nil, malformed: false)
      Result.new(kind:, value: value&.freeze, malformed:)
    end

    def identifier_like?(value)
      prefix_match?(value, Receipt::DISPLAY_ID_PREFIX) ||
        prefix_match?(value, Receipt::PUBLIC_ID_PREFIX)
    end

    def prefix_match?(value, prefix)
      candidate = value.byteslice(0, prefix.bytesize)
      candidate&.b&.downcase(:ascii) == prefix.b.downcase(:ascii)
    end
  end
end
