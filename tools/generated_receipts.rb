# frozen_string_literal: true

module GeneratedReceipts
  ROOT = File.expand_path("../spec/fixtures/generated_receipts", __dir__)
  CASES_DIR = File.join(ROOT, "cases")
  MEASUREMENT_CASES_DIR = File.join(ROOT, "measurement_cases")
  ADOPTION_EVIDENCE_CASES_DIR = File.join(ROOT, "adoption_evidence_cases")
  ADOPTION_EVIDENCE_TEXT_DIR = File.join(ROOT, "adoption_evidence_text")
  ADOPTION_EVIDENCE_IMAGES_DIR = File.join(ROOT, "adoption_evidence_images")
  TEXT_DIR = File.join(ROOT, "text")
  IMAGES_DIR = File.join(ROOT, "images")
  OCR_DIR = File.join(ROOT, "ocr")

  ENV_BLOCKED_PROCESSING_ERROR_CODES = %w[
    external_service_quota_exceeded
    external_service_auth_error
    external_service_rate_limited
    external_service_unavailable
    ocr_timeout
    ai_quota_exceeded
    ai_rate_limited
    ai_auth_error
    ai_timeout
    ai_api_error
  ].freeze

  def self.env_blocked_processing_error_code?(error_code)
    ENV_BLOCKED_PROCESSING_ERROR_CODES.include?(error_code.to_s)
  end

  def self.legacy_case_paths
    Dir[File.join(CASES_DIR, "*.json")].sort
  end

  def self.measurement_case_paths
    Dir[File.join(MEASUREMENT_CASES_DIR, "*.json")].sort
  end

  def self.case_paths
    legacy_case_paths + measurement_case_paths
  end

  def self.adoption_evidence_case_paths
    Dir[File.join(ADOPTION_EVIDENCE_CASES_DIR, "*.json")].sort
  end
end

require_relative "generated_receipts/degradation_profiles"
require_relative "generated_receipts/degrader"
require_relative "generated_receipts/measurement_contract"
require_relative "generated_receipts/validator"
require_relative "generated_receipts/text_renderer"
require_relative "generated_receipts/html_renderer"
require_relative "generated_receipts/png_renderer"
require_relative "generated_receipts/comparator"
require_relative "generated_receipts/pipeline_runner"
require_relative "generated_receipts/comparison_runner"
require_relative "generated_receipts/adoption_evidence/validator"
require_relative "generated_receipts/adoption_evidence/comparator"
