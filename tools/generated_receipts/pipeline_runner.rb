# frozen_string_literal: true

module GeneratedReceipts
  class PipelineRunner
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
      receipt = build_receipt
      run = ReceiptAnalysisRuns.start(receipt: receipt, source: "upload").run
      ocr_result = ReceiptAnalysisPipeline.run_ocr(run).ocr_result
      ai_result = nil

      if run.reload.active?
        ai_result = ReceiptAnalysisPipeline.run_ai(run: run, ocr_result: ocr_result).ai_result
      end
      ReceiptAnalysisPipeline.run_finalize(run) if run.reload.active?
      receipt.reload

      {
        receipt: receipt,
        run: run.reload,
        ocr_result: ocr_result,
        ai_result: ai_result,
        actual: Comparator.snapshot_from_receipt(receipt)
      }
    ensure
      cleanup_receipt(receipt) unless keep
    end

    private

    attr_reader :case_data, :image_path, :user, :keep

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

    def cleanup_receipt(receipt)
      return unless receipt

      receipt.image.purge if receipt.image.attached?
      receipt.destroy!
    end
  end
end
