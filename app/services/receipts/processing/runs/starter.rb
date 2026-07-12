module Receipts::Processing::Runs
  class Starter
    RUNTIME_CONFIG_ERROR_CODE = "runtime_config_unavailable".freeze
    SAFE_RECEIPT_FAILURE_MESSAGE_KEY = "receipts.processing_errors.unexpected_failure".freeze

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

        runtime_config_metadata = RuntimeConfigSnapshot.metadata_for_new_run
        run = receipt.receipt_analysis_runs.create!(
          source: source,
          stage: "queued",
          status: "queued",
          requested_by_user: requested_by_user,
          request_reason: request_reason,
          parent_run: parent_run,
          attempt_number: next_attempt_number,
          metadata: runtime_config_metadata
        )

        StartResult.new(run: run, created: true)
      end
    rescue ActiveRecord::RecordNotUnique
      active_run = latest_active_run
      raise unless active_run

      StartResult.new(run: active_run, created: false)
    rescue ExternalServices::RuntimeConfigUnavailableError
      fail_processing_receipt!
      raise
    end

    private

    attr_reader :receipt, :source, :requested_by_user, :request_reason, :parent_run

    def latest_active_run
      receipt.receipt_analysis_runs.active.order(created_at: :desc).first
    end

    def next_attempt_number
      receipt.receipt_analysis_runs.maximum(:attempt_number).to_i + 1
    end

    def fail_processing_receipt!
      receipt.with_lock do
        receipt.reload
        return unless receipt.processing?

        receipt.update!(
          status: "failed",
          processing_error_code: RUNTIME_CONFIG_ERROR_CODE,
          processing_error_message: I18n.t(SAFE_RECEIPT_FAILURE_MESSAGE_KEY),
          review_reasons: []
        )
      end
    end
  end
end
