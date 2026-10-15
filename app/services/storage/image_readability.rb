require "vips"

module Storage::ImageReadability
  LOADERS = {
    "image/jpeg" => %w[VipsForeignLoadJpegBuffer],
    "image/png" => %w[VipsForeignLoadPngBuffer],
    "image/tiff" => %w[VipsForeignLoadTiffBuffer],
    "image/heif" => %w[VipsForeignLoadHeifBuffer],
    "image/heic" => %w[VipsForeignLoadHeifBuffer],
    "image/webp" => %w[VipsForeignLoadWebpBuffer]
  }.freeze
  MULTIPAGE_CONTENT_TYPES = %w[image/tiff image/heif image/heic image/webp].freeze

  class << self
    def valid?(io:, content_type:, max_bytes:, max_dimension:)
      return false unless positive_integer?(max_bytes) && positive_integer?(max_dimension)
      return false unless LOADERS.key?(content_type)
      return false unless %i[read rewind pos seek].all? { |method| io.respond_to?(method) }

      binary = read_binary(io, max_bytes:)
      return false unless binary.is_a?(String) && binary.bytesize.between?(1, max_bytes)

      loader = Vips.vips_foreign_find_load_buffer(binary, binary.bytesize)
      return false unless LOADERS.fetch(content_type).include?(loader)

      options = { access: :sequential, fail_on: :error }
      options[:n] = -1 if MULTIPAGE_CONTENT_TYPES.include?(content_type)
      image = Vips::Image.new_from_buffer(binary, "", **options)
      return false unless bounded_dimensions?(image, max_dimension:)

      image.avg
      true
    rescue Vips::Error, IOError, SystemCallError, ArgumentError, TypeError
      false
    end

    private

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def read_binary(io, max_bytes:)
      position = io.pos
      begin
        io.rewind
        io.read(max_bytes + 1)
      ensure
        io.seek(position)
      end
    end

    def bounded_dimensions?(image, max_dimension:)
      page_height = image.get_typeof("page-height").zero? ? image.height : image.get("page-height")
      image.width.between?(1, max_dimension) &&
        page_height.between?(1, max_dimension) &&
        image.width * image.height <= max_dimension * max_dimension
    end
  end
end
