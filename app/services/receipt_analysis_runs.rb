module ReceiptAnalysisRuns
  Error = Class.new(StandardError)
  InvalidTransition = Class.new(Error)
  TerminalRunError = Class.new(Error)

  StartResult = Struct.new(:run, :created, keyword_init: true) do
    def created?
      created == true
    end
  end

  class << self
    def start(receipt:, source:, requested_by_user: nil, request_reason: nil, parent_run: nil)
      Starter.call(
        receipt: receipt,
        source: source,
        requested_by_user: requested_by_user,
        request_reason: request_reason,
        parent_run: parent_run
      )
    end

    def start_stage(run, stage, at: Time.current, provider: nil, model: nil)
      Tracker.new(run).start_stage(stage, at: at, provider: provider, model: model)
    end

    def finish_stage(run, stage, at: Time.current)
      Tracker.new(run).finish_stage(stage, at: at)
    end

    def record_ocr_result(run, ocr_result, latency_ms: nil, at: Time.current)
      Tracker.new(run).record_ocr_result(
        SnapshotBuilder.ocr_summary(ocr_result),
        latency_ms: latency_ms,
        at: at
      )
    end

    def record_ocr_snapshot(run, ocr_result, at: Time.current)
      Tracker.new(run).record_ocr_snapshot(
        SnapshotBuilder.ocr_result_snapshot(ocr_result),
        at: at
      )
    end

    def record_ai_input(run, ai_input, at: Time.current)
      Tracker.new(run).record_ai_input(
        SnapshotBuilder.ai_input_snapshot(ai_input),
        at: at
      )
    end

    def record_ai_result(run, ai_result, latency_ms: nil, at: Time.current)
      Tracker.new(run).record_ai_result(
        SnapshotBuilder.ai_result_summary(ai_result),
        latency_ms: latency_ms,
        at: at
      )
    end

    def record_ai_normalized_result(run, ai_result, at: Time.current)
      Tracker.new(run).record_ai_normalized_result(
        SnapshotBuilder.ai_normalized_result_snapshot(ai_result),
        at: at
      )
    end

    def record_final_result(run, receipt: nil, receipt_attributes: nil, items_attributes: nil, payments_attributes: nil, tax_details_attributes: nil, amount_result: nil, at: Time.current)
      Tracker.new(run).record_final_result(
        SnapshotBuilder.final_result_summary(
          receipt: receipt,
          receipt_attributes: receipt_attributes,
          items_attributes: items_attributes,
          payments_attributes: payments_attributes,
          tax_details_attributes: tax_details_attributes,
          amount_result: amount_result
        ),
        at: at
      )
    end

    def succeed(run, at: Time.current)
      Tracker.new(run).succeed(at: at)
    end

    def fail(run, error_stage:, error_code:, error_message: nil, at: Time.current)
      Tracker.new(run).fail(
        error_stage: error_stage,
        error_code: error_code,
        error_message: error_message,
        at: at
      )
    end

    def supersede(run, at: Time.current)
      Tracker.new(run).supersede(at: at)
    end

    def cancel(run, at: Time.current)
      Tracker.new(run).cancel(at: at)
    end
  end
end
