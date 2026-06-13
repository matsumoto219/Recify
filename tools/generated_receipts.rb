# frozen_string_literal: true

require_relative "generated_receipts/validator"
require_relative "generated_receipts/text_renderer"

module GeneratedReceipts
  ROOT = File.expand_path("../spec/fixtures/generated_receipts", __dir__)
  CASES_DIR = File.join(ROOT, "cases")
  TEXT_DIR = File.join(ROOT, "text")
  IMAGES_DIR = File.join(ROOT, "images")
  OCR_DIR = File.join(ROOT, "ocr")
end
