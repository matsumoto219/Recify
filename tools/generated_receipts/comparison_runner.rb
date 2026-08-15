# frozen_string_literal: true

require "json"

module GeneratedReceipts
  class ComparisonRunner
    MAX_RUNS = 2
    INVALID_RUNS_MESSAGE = "Invalid generated receipt comparison run count"

    Result = Struct.new(:case_id, :run_results, keyword_init: true) do
      VALID_STATUSES = %w[PASS WARN FAIL ENV_BLOCKED].freeze
      MAX_DIFFS = 100
      MAX_DIFF_KEYS = 16
      MAX_DIFF_DEPTH = 4
      MAX_DIFF_COLLECTION = 100
      MAX_DIFF_NODES = 16_384
      MAX_DIFF_STRING_BYTES = 512
      MAX_DIFF_KEY_BYTES = 64
      DIFF_KEYS = %w[actual expected path severity].freeze
      DIFF_SEVERITIES = %w[WARN FAIL ENV_BLOCKED].freeze
      DIFF_CONTROL_PATTERN = /[\u0000-\u0009\u000B\u000C\u000E-\u001F\u007F-\u009F]/.freeze
      DIFF_PATH_CONTROL_PATTERN = /[\u0000-\u001F\u007F-\u009F]/.freeze
      CASE_ID_PATTERN = /\Ag\d{3}_[a-z0-9_]+\z/.freeze

      def stable?
        return false unless valid_run_results?

        run_results.map { |run| stable_signature(run) }.uniq.size <= 1
      end

      def status
        return "FAIL" unless valid_run_results?

        statuses = run_results.map { |run| run_status(run) }
        return "FAIL" if statuses.include?("FAIL")
        return "ENV_BLOCKED" if statuses.include?("ENV_BLOCKED")
        return "WARN" if statuses.include?("WARN")

        "PASS"
      end

      private

      def valid_run_results?
        valid_case_id? &&
          run_results.is_a?(Array) && run_results.size.between?(1, ComparisonRunner::MAX_RUNS) &&
          run_results.all? { |run| valid_run?(run) }
      end

      def valid_case_id?
        case_id.is_a?(String) && case_id.bytesize.between?(1, MAX_DIFF_KEY_BYTES) &&
          case_id.valid_encoding? && case_id.ascii_only? && case_id.match?(CASE_ID_PATTERN)
      rescue EncodingError
        false
      end

      def valid_run?(run)
        return false unless run.is_a?(Hash)

        status = run_status(run)
        return false unless VALID_STATUSES.include?(status)

        diffs = run_diffs(run)
        node_budget = { remaining: MAX_DIFF_NODES }
        diffs.is_a?(Array) && diffs.size <= MAX_DIFFS &&
          diffs.all? { |diff| valid_diff?(diff, node_budget) } &&
          valid_status_diffs?(status, diffs) &&
          valid_comparison_consistency?(run, status, diffs)
      end

      def valid_comparison_consistency?(run, status, diffs)
        comparison = run[:comparison]
        return true if comparison.nil?
        return false unless defined?(GeneratedReceipts::Comparator::Result)
        return false unless comparison.is_a?(GeneratedReceipts::Comparator::Result)
        return false unless comparison.case_id == case_id
        return false unless valid_comparison_result?(comparison)

        status == "ENV_BLOCKED" || (
          status == comparison.status && diffs == comparison.diffs
        )
      end

      def valid_comparison_result?(comparison)
        return false unless %w[PASS WARN FAIL].include?(comparison.status)

        comparison_diffs = comparison.diffs
        node_budget = { remaining: MAX_DIFF_NODES }
        comparison_diffs.is_a?(Array) && comparison_diffs.size <= MAX_DIFFS &&
          comparison_diffs.all? { |diff| valid_diff?(diff, node_budget) } &&
          valid_status_diffs?(comparison.status, comparison_diffs)
      end

      def run_status(run)
        explicit_status = run[:status]
        return explicit_status unless explicit_status.nil?

        comparison = run[:comparison]
        comparison.status if comparison.is_a?(GeneratedReceipts::Comparator::Result)
      end

      def run_diffs(run)
        return run[:diffs] if run.key?(:diffs)

        comparison = run[:comparison]
        comparison.diffs if comparison.is_a?(GeneratedReceipts::Comparator::Result)
      end

      def stable_signature(run)
        {
          status: run_status(run),
          diffs: run_diffs(run).map { |diff| normalize_diff(diff) }
        }
      end

      def normalize_diff(diff)
        diff.to_h.transform_keys(&:to_s).sort.to_h
      end

      def valid_diff?(diff, node_budget)
        return false unless diff.is_a?(Hash) && bounded_diff_value?(diff, 0, node_budget)

        keys = diff.keys.map(&:to_s)
        return false unless keys.uniq.size == keys.size && keys.sort == DIFF_KEYS

        normalized = normalize_diff(diff)
        bounded_diff_path?(normalized["path"]) && DIFF_SEVERITIES.include?(normalized["severity"])
      end

      def valid_status_diffs?(status, diffs)
        severities = diffs.map { |diff| normalize_diff(diff)["severity"] }
        case status
        when "PASS"
          diffs.empty?
        when "WARN"
          diffs.any? && severities.all?("WARN")
        when "FAIL"
          severities.include?("FAIL")
        when "ENV_BLOCKED"
          diffs.any? && severities.all?("ENV_BLOCKED")
        else
          false
        end
      end

      def bounded_diff_path?(value)
        value.is_a?(String) && value.bytesize.between?(1, MAX_DIFF_KEY_BYTES) &&
          value.valid_encoding? && !value.match?(DIFF_PATH_CONTROL_PATTERN)
      rescue EncodingError
        false
      end

      def bounded_diff_value?(value, depth, node_budget)
        return false if depth > MAX_DIFF_DEPTH
        return false if node_budget[:remaining].zero?

        node_budget[:remaining] -= 1

        case value
        when nil, true, false
          true
        when Integer
          value.bit_length <= 256
        when Float
          value.finite?
        when String
          value.bytesize <= MAX_DIFF_STRING_BYTES && value.valid_encoding? &&
            !value.match?(DIFF_CONTROL_PATTERN)
        when Array
          value.size <= MAX_DIFF_COLLECTION && value.all? do |entry|
            bounded_diff_value?(entry, depth + 1, node_budget)
          end
        when Hash
          value.size <= MAX_DIFF_KEYS && value.all? do |key, entry|
            bounded_diff_key?(key) && bounded_diff_value?(entry, depth + 1, node_budget)
          end
        else
          false
        end
      rescue EncodingError
        false
      end

      def bounded_diff_key?(key)
        return false unless key.is_a?(String) || key.is_a?(Symbol)

        token = key.to_s
        token.bytesize <= MAX_DIFF_KEY_BYTES && token.valid_encoding? &&
          !token.match?(DIFF_CONTROL_PATTERN)
      rescue EncodingError
        false
      end
    end

    class << self
      def valid_runs?(value)
        value.is_a?(Integer) && value.between?(1, MAX_RUNS)
      end

      def compare_snapshot(case_data, actual)
        Comparator.call(case_data, actual)
      end

      def expected_snapshot(case_data)
        expected = case_data.fetch("expected")
        snapshot = {
          "store_name" => expected["store_name"],
          "subtotal" => expected["subtotal"],
          "tax" => expected["tax"],
          "total" => expected["total"],
          "tax_rate" => expected["tax_rate"],
          "tax_details" => Array(expected["tax_details"]),
          "items" => Array(expected["items"]),
          "receipt_adjustments" => Array(expected["receipt_adjustments"]),
          "payment_method" => expected["payment_method"],
          "payments" => Array(expected["payments"]).map { |payment| { "method" => payment["label"], "amount" => payment["amount"] } },
          "status" => expected["status"],
          "review_reasons" => expected["review_reasons"],
          "processing_error_code" => expected["processing_error_code"]
        }
        if expected.key?("reference_pricing_candidates")
          snapshot["reference_pricing_candidates"] = Array(expected["reference_pricing_candidates"]).reject do |candidate|
            candidate["validation_state"] == "none"
          end
        end
        snapshot
      end
    end

    def initialize(case_data, image_path:, user:, runs: 1, keep: false)
      raise ArgumentError, INVALID_RUNS_MESSAGE unless self.class.valid_runs?(runs)

      @case_data = case_data
      @image_path = image_path
      @user = user
      @runs = runs
      @keep = keep
    end

    def call
      run_results = runs.times.map do |index|
        execution = PipelineRunner.call(case_data, image_path: image_path, user: user, keep: keep)
        comparison = Comparator.call(case_data, execution[:actual])
        status = env_blocked?(execution[:actual]) ? "ENV_BLOCKED" : comparison.status
        {
          run: index.zero? ? "A" : "B",
          comparison: comparison,
          actual: execution[:actual],
          receipt_id: execution[:receipt].id,
          run_id: execution[:run].id,
          status: status,
          diffs: status == "ENV_BLOCKED" ? env_blocked_diffs(execution[:actual]) : comparison.diffs
        }
      end

      Result.new(case_id: case_data.fetch("case_id"), run_results: run_results)
    end

    private

    attr_reader :case_data, :image_path, :user, :runs, :keep

    def env_blocked?(actual)
      GeneratedReceipts.env_blocked_processing_error_code?(actual["processing_error_code"])
    end

    def env_blocked_diffs(actual)
      [
        {
          path: "processing_error_code",
          expected: nil,
          actual: actual["processing_error_code"],
          severity: "ENV_BLOCKED"
        }
      ]
    end
  end
end
