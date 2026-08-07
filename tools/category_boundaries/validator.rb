# frozen_string_literal: true

require "json"

module CategoryBoundaries
  class Validator
    Result = Struct.new(:errors, keyword_init: true) do
      def valid?
        errors.empty?
      end
    end

    SCHEMA_VERSION = 1
    TOP_LEVEL_KEYS = %w[schema_version candidate_decisions cases].freeze
    DECISION_KEYS = %w[code decision].freeze
    CASE_KEYS = %w[case_id expected_code boundary_tag needs_review].freeze
    CANDIDATE_CODES = %w[electronics clothing services office_supplies education].freeze
    CASE_ID_PATTERN = /\Acat_\d{3}_[a-z0-9_]+\z/
    BOUNDARY_TAG_PATTERN = /\A[a-z0-9]+(?:_[a-z0-9]+)*\z/

    class << self
      def call(value, allowed_codes:)
        new(value, allowed_codes: allowed_codes).call
      end

      def load_file(path = CategoryBoundaries::FIXTURE_PATH)
        JSON.parse(File.read(path))
      end
    end

    def initialize(value, allowed_codes:)
      @fixture = value
      @allowed_codes = Array(allowed_codes).map(&:to_s)
      @errors = []
    end

    def call
      validate_hash("fixture", fixture, required: TOP_LEVEL_KEYS, allowed: TOP_LEVEL_KEYS)
      return Result.new(errors: errors) unless fixture.is_a?(Hash)

      add_error("schema_version", "must equal #{SCHEMA_VERSION}") unless fixture["schema_version"] == SCHEMA_VERSION
      validate_candidate_decisions
      validate_cases

      Result.new(errors: errors)
    end

    private

    attr_reader :fixture, :allowed_codes, :errors

    def validate_candidate_decisions
      decisions = fixture["candidate_decisions"]
      return add_error("candidate_decisions", "must be an array") unless decisions.is_a?(Array)

      seen_codes = []
      decisions.each_with_index do |entry, index|
        path = "candidate_decisions[#{index}]"
        validate_hash(path, entry, required: DECISION_KEYS, allowed: DECISION_KEYS)
        next unless entry.is_a?(Hash)

        code = entry["code"]
        add_error("#{path}.code", "must be a reviewed candidate code") unless CANDIDATE_CODES.include?(code)
        add_error("#{path}.code", "must be unique") if seen_codes.include?(code)
        add_error("#{path}.decision", "must be no_go") unless entry["decision"] == "no_go"
        seen_codes << code
      end

      (CANDIDATE_CODES - seen_codes).each do |code|
        add_error("candidate_decisions", "must include #{code}")
      end
    end

    def validate_cases
      cases = fixture["cases"]
      return add_error("cases", "must be a non-empty array") unless cases.is_a?(Array) && cases.any?

      seen_ids = []
      cases.each_with_index do |entry, index|
        path = "cases[#{index}]"
        validate_hash(path, entry, required: CASE_KEYS, allowed: CASE_KEYS)
        next unless entry.is_a?(Hash)

        validate_case(path, entry, seen_ids)
        seen_ids << entry["case_id"]
      end
    end

    def validate_case(path, entry, seen_ids)
      case_id = entry["case_id"]
      add_error("#{path}.case_id", "must use the cat_NNN_name format") unless case_id.is_a?(String) && case_id.match?(CASE_ID_PATTERN)
      add_error("#{path}.case_id", "must be unique") if seen_ids.include?(case_id)

      expected_code = entry["expected_code"]
      unless expected_code.nil? || allowed_codes.include?(expected_code)
        add_error("#{path}.expected_code", "must be a canonical category code or null")
      end

      boundary_tag = entry["boundary_tag"]
      add_error("#{path}.boundary_tag", "must be snake_case") unless boundary_tag.is_a?(String) && boundary_tag.match?(BOUNDARY_TAG_PATTERN)

      needs_review = entry["needs_review"]
      add_error("#{path}.needs_review", "must be a boolean") unless [ true, false ].include?(needs_review)
      if expected_code.nil? && needs_review != true
        add_error("#{path}.needs_review", "must be true when expected_code is null")
      end
    end

    def validate_hash(path, value, required:, allowed:)
      return add_error(path, "must be an object") unless value.is_a?(Hash)

      (required - value.keys).each { |key| add_error("#{path}.#{key}", "is required") }
      (value.keys - allowed).each { |key| add_error("#{path}.#{key}", "is not allowed") }
    end

    def add_error(path, message)
      errors << "#{path}: #{message}"
    end
  end
end
