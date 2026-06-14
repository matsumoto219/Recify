# frozen_string_literal: true

require "chunky_png"

module GeneratedReceipts
  class Degrader
    class << self
      def call(case_data, image_path:)
        new(case_data, image_path: image_path).call
      end
    end

    def initialize(case_data, image_path:)
      @case_data = case_data
      @image_path = image_path
    end

    def call
      degradation = case_data.fetch("degradation", {})
      return image_path unless degradation["enabled"]

      profile = DegradationProfiles.fetch(degradation.fetch("profile"))
      image = ChunkyPNG::Image.from_file(image_path)
      image = apply_profile(image, profile)
      image.save(image_path)
      image_path
    end

    private

    attr_reader :case_data, :image_path

    def apply_profile(image, profile)
      profile.reduce(image) do |current, (effect, options)|
        case effect
        when "blur"
          blur(current, options)
        when "rotation"
          rotate(current, options)
        when "crop"
          crop(current, options)
        when "jpeg_noise"
          jpeg_noise(current, options)
        when "contrast"
          contrast(current, options)
        when "shadow"
          shadow(current, options)
        when "fold"
          fold(current, options)
        when "line_dropout"
          line_dropout(current, options)
        else
          current
        end
      end
    end

    def blur(image, options)
      iterations = options.fetch("radius", 0).to_f.ceil.clamp(0, 3)
      iterations.times.reduce(image) { |current, _index| box_blur(current) }
    end

    def box_blur(image)
      output = ChunkyPNG::Image.new(image.width, image.height, ChunkyPNG::Color::WHITE)
      image.height.times do |y|
        image.width.times do |x|
          colors = []
          (y - 1..y + 1).each do |ny|
            next if ny.negative? || ny >= image.height

            (x - 1..x + 1).each do |nx|
              next if nx.negative? || nx >= image.width

              colors << image[nx, ny]
            end
          end
          output[x, y] = average_color(colors)
        end
      end
      output
    end

    def rotate(image, options)
      degrees = options.fetch("degrees", 0).to_f
      return image if degrees.zero?

      radians = degrees * Math::PI / 180.0
      cos = Math.cos(radians)
      sin = Math.sin(radians)
      cx = (image.width - 1) / 2.0
      cy = (image.height - 1) / 2.0
      output = ChunkyPNG::Image.new(image.width, image.height, ChunkyPNG::Color::WHITE)

      image.height.times do |y|
        image.width.times do |x|
          dx = x - cx
          dy = y - cy
          source_x = (cx + dx * cos + dy * sin).round
          source_y = (cy - dx * sin + dy * cos).round
          next if source_x.negative? || source_x >= image.width || source_y.negative? || source_y >= image.height

          output[x, y] = image[source_x, source_y]
        end
      end
      output
    end

    def crop(image, options)
      top = (image.height * options.fetch("top", 0).to_f).round
      bottom = (image.height * options.fetch("bottom", 0).to_f).round
      left = (image.width * options.fetch("left", 0).to_f).round
      right = (image.width * options.fetch("right", 0).to_f).round
      output = ChunkyPNG::Image.new(image.width, image.height, ChunkyPNG::Color::WHITE)

      (top...(image.height - bottom)).each do |y|
        (left...(image.width - right)).each do |x|
          output[x, y] = image[x, y]
        end
      end
      output
    end

    def jpeg_noise(image, options)
      strength = ((100 - options.fetch("quality", 90).to_i).clamp(0, 100) / 100.0 * 22).round
      return image if strength.zero?

      map_pixels(image) do |color, x, y|
        delta = deterministic_noise(x, y, strength)
        adjust_color(color) { |value| (value + delta).clamp(0, 255) }
      end
    end

    def contrast(image, options)
      factor = options.fetch("factor", 1.0).to_f
      map_pixels(image) do |color, _x, _y|
        adjust_color(color) { |value| (128 + (value - 128) * factor).round.clamp(0, 255) }
      end
    end

    def shadow(image, options)
      opacity = options.fetch("opacity", 0).to_f.clamp(0, 0.5)
      map_pixels(image) do |color, x, y|
        ratio = ((x.to_f / [ image.width - 1, 1 ].max) * 0.65) + ((y.to_f / [ image.height - 1, 1 ].max) * 0.35)
        factor = 1.0 - opacity * ratio
        adjust_color(color) { |value| (value * factor).round.clamp(0, 255) }
      end
    end

    def fold(image, options)
      opacity = options.fetch("opacity", 0).to_f.clamp(0, 0.4)
      center = image.width / 2
      width = [ (image.width * 0.035).round, 3 ].max
      map_pixels(image) do |color, x, _y|
        distance = (x - center).abs
        next color if distance > width

        factor = 1.0 - opacity * (1.0 - distance.to_f / width)
        adjust_color(color) { |value| (value * factor).round.clamp(0, 255) }
      end
    end

    def line_dropout(image, options)
      probability = options.fetch("probability", 0).to_f
      return image if probability <= 0

      interval = (1.0 / probability).round.clamp(12, 80)
      map_pixels(image) do |color, _x, y|
        y % interval < 2 ? ChunkyPNG::Color::WHITE : color
      end
    end

    def map_pixels(image)
      output = ChunkyPNG::Image.new(image.width, image.height, ChunkyPNG::Color::WHITE)
      image.height.times do |y|
        image.width.times do |x|
          output[x, y] = yield(image[x, y], x, y)
        end
      end
      output
    end

    def average_color(colors)
      red = colors.sum { |color| ChunkyPNG::Color.r(color) } / colors.size
      green = colors.sum { |color| ChunkyPNG::Color.g(color) } / colors.size
      blue = colors.sum { |color| ChunkyPNG::Color.b(color) } / colors.size
      alpha = colors.sum { |color| ChunkyPNG::Color.a(color) } / colors.size
      ChunkyPNG::Color.rgba(red, green, blue, alpha)
    end

    def adjust_color(color)
      ChunkyPNG::Color.rgba(
        yield(ChunkyPNG::Color.r(color)),
        yield(ChunkyPNG::Color.g(color)),
        yield(ChunkyPNG::Color.b(color)),
        ChunkyPNG::Color.a(color)
      )
    end

    def deterministic_noise(x, y, strength)
      seed = (x * 73_856_093) ^ (y * 19_349_663) ^ case_seed
      ((seed % (strength * 2 + 1)) - strength)
    end

    def case_seed
      @case_seed ||= case_data.fetch("case_id").bytes.each_with_index.sum { |byte, index| byte * (index + 1) }
    end
  end
end
