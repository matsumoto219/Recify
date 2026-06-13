# frozen_string_literal: true

module GeneratedReceipts
  module DegradationProfiles
    EFFECTS = %w[
      blur
      rotation
      crop
      jpeg_noise
      contrast
      shadow
      fold
      line_dropout
    ].freeze

    PROFILES = {
      "mild" => {
        "blur" => { "radius" => 0.4 },
        "rotation" => { "degrees" => 1.0 },
        "contrast" => { "factor" => 0.95 }
      },
      "medium" => {
        "blur" => { "radius" => 0.9 },
        "rotation" => { "degrees" => 2.5 },
        "jpeg_noise" => { "quality" => 82 },
        "shadow" => { "opacity" => 0.12 }
      },
      "severe" => {
        "blur" => { "radius" => 1.4 },
        "rotation" => { "degrees" => 4.0 },
        "crop" => { "top" => 0.02, "bottom" => 0.03 },
        "jpeg_noise" => { "quality" => 68 },
        "shadow" => { "opacity" => 0.22 },
        "fold" => { "opacity" => 0.18 },
        "line_dropout" => { "probability" => 0.04 }
      }
    }.freeze

    module_function

    def names
      PROFILES.keys
    end

    def fetch(name)
      PROFILES.fetch(name)
    end
  end
end
