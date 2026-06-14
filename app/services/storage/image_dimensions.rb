module Storage::ImageDimensions
  PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b
  RIFF_SIGNATURE = "RIFF".b
  WEBP_SIGNATURE = "WEBP".b
  JPEG_SOF_MARKERS = [
    0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
    0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF
  ].freeze
  HEIF_CONTAINER_BOX_TYPES = %w[meta iprp ipco].freeze

  class << self
    def extract(blob:, attached_change: nil)
      metadata_dimensions(blob) ||
        attached_change_dimensions(attached_change, content_type: blob.content_type) ||
        persisted_blob_dimensions(blob)
    end

    private

    def metadata_dimensions(blob)
      metadata = blob.metadata || {}
      width = integer_from(metadata["width"] || metadata[:width])
      height = integer_from(metadata["height"] || metadata[:height])
      return if width.blank? || height.blank?

      positive_dimensions(width, height)
    end

    def attached_change_dimensions(attached_change, content_type:)
      binary = attached_binary(attached_change&.attachable)
      return if binary.blank?

      dimensions_from_binary(binary, content_type: content_type)
    rescue StandardError
      nil
    end

    def persisted_blob_dimensions(blob)
      return unless blob.persisted?

      dimensions_from_binary(blob.download, content_type: blob.content_type)
    rescue StandardError
      nil
    end

    def attached_binary(attachable)
      case attachable
      when Hash
        read_io(attachable[:io] || attachable["io"])
      when String, Pathname
        File.binread(attachable.to_s) if File.file?(attachable.to_s)
      else
        if attachable.respond_to?(:tempfile)
          read_io(attachable.tempfile)
        elsif attachable.respond_to?(:to_io)
          read_io(attachable.to_io)
        elsif attachable.respond_to?(:read)
          read_io(attachable)
        end
      end
    end

    def read_io(io)
      return unless io.respond_to?(:read)

      position = io.pos if io.respond_to?(:pos)
      io.rewind if io.respond_to?(:rewind)
      io.read.to_s.b
    ensure
      io.seek(position) if position && io.respond_to?(:seek)
    end

    def dimensions_from_binary(binary, content_type:)
      data = binary.to_s.b

      case content_type
      when "image/png"
        png_dimensions(data)
      when "image/jpeg"
        jpeg_dimensions(data)
      when "image/bmp"
        bmp_dimensions(data)
      when "image/tiff"
        tiff_dimensions(data)
      when "image/heic", "image/heif"
        heif_dimensions(data)
      when "image/webp"
        webp_dimensions(data)
      end
    end

    def png_dimensions(data)
      return unless data.bytesize >= 24 && data.start_with?(PNG_SIGNATURE)

      width, height = data.byteslice(16, 8).unpack("N2")
      positive_dimensions(width, height)
    end

    def jpeg_dimensions(data)
      return unless data.bytesize >= 4 && data.getbyte(0) == 0xFF && data.getbyte(1) == 0xD8

      offset = 2
      while offset < data.bytesize
        offset += 1 while offset < data.bytesize && data.getbyte(offset) != 0xFF
        offset += 1 while offset < data.bytesize && data.getbyte(offset) == 0xFF
        marker = data.getbyte(offset)
        offset += 1
        next if marker.nil? || marker == 0x00
        return if marker == 0xD9 || marker == 0xDA
        next if marker == 0x01 || (0xD0..0xD7).cover?(marker)
        return if offset + 2 > data.bytesize

        segment_length = data.byteslice(offset, 2).unpack1("n")
        return if segment_length.nil? || segment_length < 2

        if JPEG_SOF_MARKERS.include?(marker)
          return if offset + 7 > data.bytesize

          height, width = data.byteslice(offset + 3, 4).unpack("n2")
          return positive_dimensions(width, height)
        end

        offset += segment_length
      end

      nil
    end

    def bmp_dimensions(data)
      return unless data.bytesize >= 26 && data.start_with?("BM")

      width, height = data.byteslice(18, 8).unpack("l<l<")
      positive_dimensions(width&.abs, height&.abs)
    end

    def tiff_dimensions(data)
      return unless data.bytesize >= 8

      endian = data.byteslice(0, 2)
      little_endian =
        case endian
        when "II" then true
        when "MM" then false
        else return
        end
      return unless read_uint16(data, 2, little_endian) == 42

      ifd_offset = read_uint32(data, 4, little_endian)
      return if ifd_offset.blank? || ifd_offset + 2 > data.bytesize

      entry_count = read_uint16(data, ifd_offset, little_endian)
      return if entry_count.blank?

      width = nil
      height = nil
      entry_offset = ifd_offset + 2
      entry_count.times do
        break if entry_offset + 12 > data.bytesize

        tag = read_uint16(data, entry_offset, little_endian)
        type = read_uint16(data, entry_offset + 2, little_endian)
        count = read_uint32(data, entry_offset + 4, little_endian)
        value = tiff_inline_value(data, entry_offset + 8, type, count, little_endian)
        width = value if tag == 256
        height = value if tag == 257
        entry_offset += 12
      end

      positive_dimensions(width, height)
    end

    def tiff_inline_value(data, offset, type, count, little_endian)
      return unless count == 1

      case type
      when 3
        read_uint16(data, offset, little_endian)
      when 4
        read_uint32(data, offset, little_endian)
      end
    end

    def heif_dimensions(data)
      find_ispe_dimensions(data, 0, data.bytesize)
    end

    def webp_dimensions(data)
      return unless data.bytesize >= 20
      return unless data.start_with?(RIFF_SIGNATURE) && data.byteslice(8, 4) == WEBP_SIGNATURE

      chunk_type = data.byteslice(12, 4)
      case chunk_type
      when "VP8X"
        webp_vp8x_dimensions(data)
      when "VP8L"
        webp_vp8l_dimensions(data)
      when "VP8 "
        webp_vp8_dimensions(data)
      end
    end

    def webp_vp8x_dimensions(data)
      return if data.bytesize < 30

      width = read_uint24_le(data, 24)
      height = read_uint24_le(data, 27)
      return if width.nil? || height.nil?

      positive_dimensions(width + 1, height + 1)
    end

    def webp_vp8l_dimensions(data)
      return if data.bytesize < 25
      return unless data.getbyte(20) == 0x2F

      b0 = data.getbyte(21)
      b1 = data.getbyte(22)
      b2 = data.getbyte(23)
      b3 = data.getbyte(24)
      return if [ b0, b1, b2, b3 ].any?(&:nil?)

      width = 1 + (((b1 & 0x3F) << 8) | b0)
      height = 1 + (((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6))
      positive_dimensions(width, height)
    end

    def webp_vp8_dimensions(data)
      payload_offset = 20
      return if data.bytesize < payload_offset + 10
      return unless data.getbyte(payload_offset + 3) == 0x9D &&
                    data.getbyte(payload_offset + 4) == 0x01 &&
                    data.getbyte(payload_offset + 5) == 0x2A

      width = read_uint16(data, payload_offset + 6, true)&.then { |value| value & 0x3FFF }
      height = read_uint16(data, payload_offset + 8, true)&.then { |value| value & 0x3FFF }
      positive_dimensions(width, height)
    end

    def find_ispe_dimensions(data, start_offset, end_offset)
      offset = start_offset
      while offset + 8 <= end_offset
        box_size = read_uint32(data, offset, false)
        box_type = data.byteslice(offset + 4, 4)
        return if box_size.blank? || box_size < 8

        header_size = 8
        if box_size == 1
          return if offset + 16 > end_offset

          box_size = data.byteslice(offset + 8, 8).unpack1("Q>")
          header_size = 16
        end

        box_end = offset + box_size
        return if box_end > end_offset

        if box_type == "ispe"
          return parse_ispe_box(data, offset + header_size, box_end)
        end

        if HEIF_CONTAINER_BOX_TYPES.include?(box_type)
          child_start = offset + header_size
          child_start += 4 if box_type == "meta"
          dimensions = find_ispe_dimensions(data, child_start, box_end)
          return dimensions if dimensions
        end

        offset = box_end
      end

      nil
    end

    def parse_ispe_box(data, content_offset, box_end)
      return if content_offset + 12 > box_end

      width = read_uint32(data, content_offset + 4, false)
      height = read_uint32(data, content_offset + 8, false)
      positive_dimensions(width, height)
    end

    def read_uint16(data, offset, little_endian)
      return if offset + 2 > data.bytesize

      data.byteslice(offset, 2).unpack1(little_endian ? "v" : "n")
    end

    def read_uint32(data, offset, little_endian)
      return if offset + 4 > data.bytesize

      data.byteslice(offset, 4).unpack1(little_endian ? "V" : "N")
    end

    def read_uint24_le(data, offset)
      return if offset + 3 > data.bytesize

      bytes = data.byteslice(offset, 3).bytes
      bytes[0] | (bytes[1] << 8) | (bytes[2] << 16)
    end

    def positive_dimensions(width, height)
      width = integer_from(width)
      height = integer_from(height)
      return if width.blank? || height.blank? || width <= 0 || height <= 0

      { width: width, height: height }
    end

    def integer_from(value)
      Integer(value, exception: false)
    end
  end
end
