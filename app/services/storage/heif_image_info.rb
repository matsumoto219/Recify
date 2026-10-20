require "vips"

module Storage::HeifImageInfo
  class << self
    def extract(binary:)
      return unless binary.is_a?(String) && !binary.empty?
      return unless Vips.vips_foreign_find_load_buffer(binary, binary.bytesize) == "VipsForeignLoadHeifBuffer"

      image = Vips::Image.new_from_buffer(binary, "", access: :sequential, fail_on: :error)
      # This codec metadata belongs to the primary image; page readability is checked separately.
      return unless image.get_typeof("heif-compression").positive? && image.get("heif-compression") == "hevc"
      return unless image.width.positive? && image.height.positive?

      { content_type: "image/heic", width: image.width, height: image.height }
    rescue Vips::Error, ArgumentError, TypeError
      nil
    end
  end
end
