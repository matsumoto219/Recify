# frozen_string_literal: true

require "json"

module GeneratedReceipts
  class ComparisonRunner
    Result = Struct.new(:case_id, :run_results, keyword_init: true) do
      def stable?
        run_results.map { |run| stable_signature(run) }.uniq.size <= 1
      end

      def status
        statuses = run_results.map { |run| run[:status] || run[:comparison].status }
        return "FAIL" if statuses.include?("FAIL")
        return "ENV_BLOCKED" if statuses.include?("ENV_BLOCKED")
        return "WARN" if statuses.include?("WARN")

        "PASS"
      end

      private

      def stable_signature(run)
        {
          status: run[:status] || run[:comparison].status,
          diffs: Array(run[:diffs] || run[:comparison].diffs).map { |diff| normalize_diff(diff) }
        }
      end

      def normalize_diff(diff)
        diff.to_h.transform_keys(&:to_s).sort.to_h
      end
    end

    class << self
      def compare_snapshot(case_data, actual)
        Comparator.call(case_data, actual)
      end

      def expected_snapshot(case_data)
        expected = case_data.fetch("expected")
        {
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
      end
    end

    def initialize(case_data, image_path:, user:, runs: 1, keep: false)
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
