class Ocr::ResponseParser::AzureStringIndexMapper
  MAX_CONTENT_BYTES = 1_048_576
  MAX_PROVIDER_INDEX = 10_000_000
  SUPPORTED_INDEX_TYPES = %w[utf16CodeUnit textElements].freeze
  TEXT_ELEMENT_PATTERN = /\X/u

  def self.build(index_type:)
    return unless index_type.is_a?(String) && SUPPORTED_INDEX_TYPES.include?(index_type)

    new(index_type:)
  end
  private_class_method :new

  def initialize(index_type:)
    @index_type = index_type
  end

  attr_reader :index_type

  def length(content)
    return unless valid_content?(content)

    total = 0
    each_index_segment(content) do |_byte_length, provider_length|
      total += provider_length
      return if total > MAX_PROVIDER_INDEX
    end
    total
  rescue ArgumentError, EncodingError
    nil
  end

  def slice(content, offset:, length:)
    byte_range = byte_range_for_span(content, offset:, length:)
    return if byte_range.nil?

    content.byteslice(byte_range)
  rescue ArgumentError, EncodingError
    nil
  end

  def byte_range_for_span(content, offset:, length:)
    return unless valid_range?(offset, length)
    return unless valid_content?(content)

    ending = offset + length
    index = boundary_index(content)
    return if index.nil?

    start_byte = exact_boundary_value(index[:provider_offsets], index[:byte_offsets], offset)
    return if start_byte.nil?

    end_byte = exact_boundary_value(index[:provider_offsets], index[:byte_offsets], ending)
    return if end_byte.nil?

    start_byte...end_byte
  rescue ArgumentError, EncodingError
    nil
  end

  def span_for_bytes(content, byte_offset:, byte_length:)
    return unless valid_range?(byte_offset, byte_length)
    return unless valid_content?(content)
    return if byte_offset + byte_length > content.bytesize

    index = boundary_index(content)
    return if index.nil?

    start_offset = exact_boundary_value(index[:byte_offsets], index[:provider_offsets], byte_offset)
    return if start_offset.nil?

    end_offset = exact_boundary_value(
      index[:byte_offsets],
      index[:provider_offsets],
      byte_offset + byte_length
    )
    return if end_offset.nil?

    { offset: start_offset, length: end_offset - start_offset }
  rescue ArgumentError, EncodingError
    nil
  end

  private

  def valid_content?(content)
    return false unless content.is_a?(String)
    return false if content.bytesize > MAX_CONTENT_BYTES
    return false unless content.encoding == Encoding::UTF_8 || content.encoding == Encoding::US_ASCII

    content.valid_encoding?
  end

  def valid_range?(offset, length)
    return false unless offset.is_a?(Integer) && length.is_a?(Integer)
    return false if offset.negative? || length.negative?
    return false if offset > MAX_PROVIDER_INDEX || length > MAX_PROVIDER_INDEX

    length <= MAX_PROVIDER_INDEX - offset
  end

  def boundary_index(content)
    return @boundary_index if defined?(@boundary_content) && @boundary_content.equal?(content)

    byte_offsets = [ 0 ]
    provider_offsets = [ 0 ]
    byte_offset = 0
    provider_offset = 0
    each_index_segment(content) do |byte_length, provider_length|
      byte_offset += byte_length
      provider_offset += provider_length
      return if provider_offset > MAX_PROVIDER_INDEX

      byte_offsets << byte_offset
      provider_offsets << provider_offset
    end

    index = { byte_offsets:, provider_offsets: }
    if content.frozen? && (!defined?(@boundary_content) || content.bytesize > @boundary_content.bytesize)
      @boundary_content = content
      @boundary_index = index
    end
    index
  end

  def exact_boundary_value(search_offsets, result_offsets, target)
    index = search_offsets.bsearch_index { |offset| offset >= target }
    return if index.nil? || search_offsets.fetch(index) != target

    result_offsets.fetch(index)
  end

  def each_index_segment(content)
    if index_type == "utf16CodeUnit"
      content.each_char do |character|
        yield character.bytesize, character.ord > 0xFFFF ? 2 : 1
      end
    else
      content.scan(TEXT_ELEMENT_PATTERN) do |text_element|
        yield text_element.bytesize, 1
      end
    end
  end
end
