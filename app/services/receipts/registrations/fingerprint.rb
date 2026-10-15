require "digest"
require "openssl"

class Receipts::Registrations::Fingerprint
  MAX_DEPTH = 12
  MAX_NODES = 400_000
  MAX_INPUT_BYTES = 8.megabytes
  MAX_STRING_BYTES = 4_096
  MAX_FILES = 20
  MAX_FILE_BYTES = 50.megabytes
  NESTED_ROWS = %w[receipt_items_attributes receipt_adjustments_attributes receipt_payments_attributes].freeze
  private_constant :MAX_DEPTH, :MAX_NODES, :MAX_INPUT_BYTES, :MAX_STRING_BYTES, :MAX_FILES, :MAX_FILE_BYTES, :NESTED_ROWS

  def self.call(user:, kind:, input:)
    new(user:, kind:).call(input)
  end

  def initialize(user:, kind:)
    @user = user
    @kind = kind
    @nodes = 0
    @bytes = 0
    @files = 0
  end

  def call(input)
    invalid! unless %w[upload batch_upload manual].include?(@kind)
    payload = [ @user.id, @kind, canonical(input, depth: 0) ]
    key = Rails.application.key_generator.generate_key("receipt-registration-input-v1", 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, JSON.generate(payload))
  end

  private

  def canonical(value, depth:)
    @nodes += 1
    invalid! if depth > MAX_DEPTH || @nodes > MAX_NODES
    return file_value(value) if value.respond_to?(:tempfile) && value.respond_to?(:content_type)

    case value
    when Hash
      hash_value(value, depth:)
    when Array
      invalid! if value.length > MAX_NODES - @nodes
      value.map { |entry| canonical(entry, depth: depth + 1) }
    when String
      string_value(value)
    when BigDecimal
      invalid! unless value.finite?
      [ "decimal", string_value(value.to_s("F")) ]
    when Integer
      [ "integer", string_value(value.to_s) ]
    when TrueClass, FalseClass, NilClass
      value
    when Date
      [ "date", value.iso8601 ]
    when Time, ActiveSupport::TimeWithZone
      [ "time", value.utc.iso8601(6) ]
    else
      invalid!
    end
  end

  def hash_value(value, depth:)
    invalid! if value.size > MAX_NODES - @nodes
    keys = value.keys
    invalid! unless keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
    invalid! unless keys.map(&:to_s).uniq.size == keys.size

    keys.sort_by(&:to_s).to_h do |key|
      name = string_value(key.to_s)
      entry = value.fetch(key)
      if NESTED_ROWS.include?(name) && entry.is_a?(Hash)
        invalid! unless entry.keys.all? { |index| /\A\d{1,20}\z/.match?(index.to_s) }
        entry = entry.values
      end
      [ name, canonical(entry, depth: depth + 1) ]
    end
  end

  def string_value(value)
    @bytes += value.bytesize
    invalid! unless value.valid_encoding? && value.encoding.ascii_compatible? &&
      value.bytesize <= MAX_STRING_BYTES && @bytes <= MAX_INPUT_BYTES

    value
  end

  def file_value(value)
    @files += 1
    io = value.tempfile
    invalid! unless @files <= MAX_FILES && io.respond_to?(:read) && io.respond_to?(:rewind) &&
      io.respond_to?(:pos) && io.respond_to?(:seek)

    original_position = io.pos
    size = 0
    digest = Digest::SHA256.new
    io.rewind
    while (chunk = io.read(64.kilobytes))
      size += chunk.bytesize
      invalid! if size > MAX_FILE_BYTES
      digest.update(chunk)
    end
    [ "image", size, digest.hexdigest ]
  ensure
    io.seek(original_position) if io && original_position
  end

  def invalid!
    raise ArgumentError, "invalid registration input"
  end
end
