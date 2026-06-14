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
        "blur" => { "radius" => 1.0 },
        "rotation" => { "degrees" => 2.0 },
        "crop" => { "top" => 0.005, "bottom" => 0.005 },
        "jpeg_noise" => { "quality" => 78 },
        "shadow" => { "opacity" => 0.16 },
        "fold" => { "opacity" => 0.1 },
        "line_dropout" => { "probability" => 0.0 }
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
