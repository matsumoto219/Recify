# frozen_string_literal: true

module CategoryBoundaries
  ROOT = File.expand_path("../spec/fixtures/category_boundaries", __dir__)
  FIXTURE_PATH = File.join(ROOT, "cases.json")
end

require_relative "category_boundaries/validator"
