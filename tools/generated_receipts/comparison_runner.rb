# frozen_string_literal: true

require "json"

module GeneratedReceipts
  class ComparisonRunner
    Result = Struct.new(:case_id, :run_results, keyword_init: true) do
      def stable?
        snapshots = run_results.map { |run| run[:actual] }
        snapshots.uniq.size <= 1
      end

      def status
        statuses = run_results.map { |run| run[:comparison].status }
        return "FAIL" if statuses.include?("FAIL")
        return "WARN" if statuses.include?("WARN")

        "PASS"
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
          "tax_details" => expected["tax_details"],
          "items" => expected["items"],
          "receipt_adjustments" => expected["receipt_adjustments"],
          "payment_method" => expected["payment_method"],
          "payments" => expected["payments"].map { |payment| { "method" => payment["label"], "amount" => payment["amount"] } },
          "status" => expected["status"],
          "review_reasons" => expected["review_reasons"]
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
        {
          run: index.zero? ? "A" : "B",
          comparison: comparison,
          actual: execution[:actual],
          receipt_id: execution[:receipt].id,
          run_id: execution[:run].id,
          status: comparison.status,
          diffs: comparison.diffs
        }
      end

      Result.new(case_id: case_data.fetch("case_id"), run_results: run_results)
    end

    private

    attr_reader :case_data, :image_path, :user, :runs, :keep
  end
end
