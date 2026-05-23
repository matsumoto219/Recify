module ReceiptAnalysisRuns
  class Starter
    class << self
      def call(receipt:, source:, requested_by_user: nil, request_reason: nil, parent_run: nil)
        new(
          receipt: receipt,
          source: source,
          requested_by_user: requested_by_user,
          request_reason: request_reason,
          parent_run: parent_run
        ).call
      end
    end

    def initialize(receipt:, source:, requested_by_user: nil, request_reason: nil, parent_run: nil)
      @receipt = receipt
      @source = source
      @requested_by_user = requested_by_user
      @request_reason = request_reason
      @parent_run = parent_run
    end

    def call
      receipt.with_lock do
        if (active_run = latest_active_run)
          return StartResult.new(run: active_run, created: false)
        end

        run = receipt.receipt_analysis_runs.create!(
          source: source,
          stage: "queued",
          status: "queued",
          requested_by_user: requested_by_user,
          request_reason: request_reason,
          parent_run: parent_run,
          attempt_number: next_attempt_number
        )

        StartResult.new(run: run, created: true)
      end
    rescue ActiveRecord::RecordNotUnique
      active_run = latest_active_run
      raise unless active_run

      StartResult.new(run: active_run, created: false)
    end

    private

    attr_reader :receipt, :source, :requested_by_user, :request_reason, :parent_run

    def latest_active_run
      receipt.receipt_analysis_runs.active.order(created_at: :desc).first
    end

    def next_attempt_number
      receipt.receipt_analysis_runs.maximum(:attempt_number).to_i + 1
    end
  end
end
