require "vips"

module Storage::ImageReadability
  LOADERS = {
    "image/jpeg" => %w[VipsForeignLoadJpegBuffer VipsForeignLoadUhdrBuffer],
    "image/png" => %w[VipsForeignLoadPngBuffer],
    "image/tiff" => %w[VipsForeignLoadTiffBuffer],
    "image/heif" => %w[VipsForeignLoadHeifBuffer],
    "image/heic" => %w[VipsForeignLoadHeifBuffer],
    "image/webp" => %w[VipsForeignLoadWebpBuffer]
  }.freeze
  MULTIPAGE_CONTENT_TYPES = %w[image/tiff image/heif image/heic image/webp].freeze

  class << self
    def valid?(io:, content_type:, max_bytes:, max_dimension:)
      validation_error(io:, content_type:, max_bytes:, max_dimension:).nil?
    end

    def validation_error(io:, content_type:, max_bytes:, max_dimension:)
      return :unreadable_image unless positive_integer?(max_bytes) && positive_integer?(max_dimension)
      return :invalid_content_type unless LOADERS.key?(content_type)
      return :unreadable_image unless %i[read rewind pos seek].all? { |method| io.respond_to?(method) }

      binary = read_binary(io, max_bytes:)
      return :unreadable_image unless binary.is_a?(String) && binary.bytesize.between?(1, max_bytes)

      loader = Vips.vips_foreign_find_load_buffer(binary, binary.bytesize)
      return :unreadable_image unless loader
      return :invalid_content_type unless LOADERS.fetch(content_type).include?(loader)

      options = { access: :sequential, fail_on: :error }
      return validate_tiff(binary, options:, max_dimension:) if content_type == "image/tiff"

      image = Vips::Image.new_from_buffer(binary, "", **options)
      if loader == "VipsForeignLoadHeifBuffer" && image.get("heif-compression") != "hevc"
        return :invalid_content_type
      end
      if MULTIPAGE_CONTENT_TYPES.include?(content_type)
        page_count = image.get_typeof("n-pages").zero? ? 1 : image.get("n-pages")
        return :unreadable_image unless positive_integer?(page_count)

        validate_pages(binary, options:, page_count:, max_dimension:)
      else
        validate_image(image, max_dimension:)
      end
    rescue Vips::Error, IOError, SystemCallError, ArgumentError, TypeError
      :unreadable_image
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

    def validate_pages(binary, options:, page_count:, max_dimension:)
      remaining_pixels = max_dimension * max_dimension
      page_count.times do |page|
        image = Vips::Image.new_from_buffer(binary, "", **options, page:, n: 1)
        remaining_pixels -= image.width * image.height
        return :image_pixel_limit_exceeded if remaining_pixels.negative?

        error = validate_image(image, max_dimension:)
        return error if error
      end
      nil
    end

    def validate_tiff(binary, options:, max_dimension:)
      remaining_pixels = max_dimension * max_dimension
      # Validate the full directory chain once; decoding page N from the original
      # repeatedly scans that chain. Each source owns a duplicate descriptor, so
      # cached native objects never reference temporary Ruby string memory.
      pages = Storage::TiffPageCount.each_page(binary) do |file|
        source = Vips::Source.new_from_descriptor(file.fileno)
        image = Vips::Image.new_from_source(source, "", **options)
        remaining_pixels -= image.width * image.height
        return :image_pixel_limit_exceeded if remaining_pixels.negative?

        error = validate_image(image, max_dimension:)
        return error if error
      end
      pages ? nil : :unreadable_image
    end

    def validate_image(image, max_dimension:)
      unless image.width.between?(1, max_dimension) && image.height.between?(1, max_dimension)
        return :image_pixel_limit_exceeded
      end

      image.avg
      nil
    end
  end
end
