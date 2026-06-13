# frozen_string_literal: true

module GeneratedReceipts
  class PipelineRunner
    MAX_ATTEMPTS = 3
    RETRY_BACKOFF_SECONDS = 2

    class << self
      def call(case_data, image_path:, user:, keep: false)
        new(case_data, image_path: image_path, user: user, keep: keep).call
      end
    end

    def initialize(case_data, image_path:, user:, keep: false)
      @case_data = case_data
      @image_path = image_path
      @user = user
      @keep = keep
    end

    def call
      execution = nil
      MAX_ATTEMPTS.times do |attempt|
        execution = run_once
        break unless retryable_unprocessed_failure?(execution) && attempt < MAX_ATTEMPTS - 1

        cleanup_receipt(execution[:receipt]) unless keep
        execution = nil
        sleep RETRY_BACKOFF_SECONDS * (attempt + 1)
      end

      execution
    ensure
      cleanup_receipt(execution[:receipt]) if execution && !keep
    end

    private

    attr_reader :case_data, :image_path, :user, :keep

    def run_once
      receipt = build_receipt
      run = ReceiptAnalysisRuns.start(receipt: receipt, source: "upload").run
      ocr_execution = ReceiptAnalysisPipeline.run_ocr(run)
      ocr_result = ocr_execution.ocr_result
      ai_result = nil
      next_step = ocr_execution.next_step

      if next_step == :ai && run.reload.active?
        ai_execution = ReceiptAnalysisPipeline.run_ai(run: run, ocr_result: ocr_result)
        ai_result = ai_execution.ai_result
        next_step = ai_execution.next_step
      end
      ReceiptAnalysisPipeline.run_finalize(run) if next_step == :finalize && run.reload.active?
      receipt.reload

      {
        receipt: receipt,
        run: run.reload,
        ocr_result: ocr_result,
        ai_result: ai_result,
        actual: Comparator.snapshot_from_receipt(receipt)
      }
    rescue StandardError
      cleanup_receipt(receipt) unless keep
      raise
    end

    def build_receipt
      user.receipts.create!(
        store_name: "Generated Receipt Probe",
        total_amount: 1,
        payment_method: "cash",
        status: "uploaded"
      ).tap do |receipt|
        receipt.image.attach(
          io: File.open(image_path, "rb"),
          filename: File.basename(image_path),
          content_type: "image/png"
        )
        receipt.update!(status: "processing")
      end
    end

    def retryable_unprocessed_failure?(execution)
      return false unless case_data["receipt_kind"] == "receipt"

      actual = execution[:actual]
      return false if GeneratedReceipts.env_blocked_processing_error_code?(actual["processing_error_code"])

      actual["status"] == "failed" &&
        actual["store_name"] == "Generated Receipt Probe" &&
        actual["total"] == 1 &&
        actual["subtotal"].nil? &&
        actual["tax"].nil? &&
        Array(actual["items"]).empty? &&
        Array(actual["tax_details"]).empty? &&
        Array(actual["payments"]).empty?
    end

    def cleanup_receipt(receipt)
      return unless receipt

      receipt.image.purge if receipt.image.attached?
      receipt.destroy!
    end
  end
end
