module ReceiptAnalysisRuns
  class Tracker
    TERMINAL_STATUSES = %w[succeeded failed skipped superseded canceled].freeze
    STARTABLE_STAGES = %w[ocr ocr_validation ai finalize].freeze
    FINISHABLE_STAGES = %w[ocr ocr_validation ai finalize].freeze
    NEXT_STAGE = {
      "ocr" => "ocr_validation",
      "ocr_validation" => "ai",
      "ai" => "finalize",
      "finalize" => "completed"
    }.freeze

    def initialize(run)
      @run = run
    end

    def start_stage(stage, at: Time.current, provider: nil, model: nil)
      stage = normalize_stage!(stage, allowed: STARTABLE_STAGES)

      with_mutable_run do |locked_run|
        ensure_forward_transition!(locked_run, stage)

        attrs = {
          stage: stage,
          status: "running",
          started_at: locked_run.started_at || at
        }
        attrs.merge!(stage_start_attributes(stage, at: at, provider: provider, model: model))

        locked_run.update!(attrs)
        locked_run
      end
    end

    def finish_stage(stage, at: Time.current)
      stage = normalize_stage!(stage, allowed: FINISHABLE_STAGES)

      with_mutable_run do |locked_run|
        unless locked_run.stage == stage
          raise InvalidTransition, "Cannot finish stage=#{stage} from stage=#{locked_run.stage}"
        end

        attrs = stage_finish_attributes(locked_run, stage, at: at)
        attrs[:stage] = NEXT_STAGE.fetch(stage)

        locked_run.update!(attrs)
        locked_run
      end
    end

    def record_ocr_result(summary, latency_ms: nil, at: Time.current)
      summary = summary.to_h

      with_mutable_run do |locked_run|
        locked_run.update!(
          stage: advanced_stage(locked_run, "ocr_validation"),
          status: "running",
          started_at: locked_run.started_at || at,
          ocr_finished_at: locked_run.ocr_finished_at || at,
          ocr_latency_ms: latency_ms || locked_run.ocr_latency_ms || latency_from(locked_run.ocr_started_at, at),
          ocr_provider: summary["provider"].presence || locked_run.ocr_provider,
          ocr_model: summary["model"].presence || locked_run.ocr_model,
          ocr_summary: summary
        )
        locked_run
      end
    end

    def record_ai_input(snapshot, at: Time.current)
      snapshot = snapshot.to_h

      with_mutable_run do |locked_run|
        locked_run.update!(
          stage: advanced_stage(locked_run, "ai"),
          status: "running",
          started_at: locked_run.started_at || at,
          ai_started_at: locked_run.ai_started_at || at,
          ai_input_snapshot: snapshot
        )
        locked_run
      end
    end

    def record_ai_result(summary, latency_ms: nil, at: Time.current)
      summary = summary.to_h

      with_mutable_run do |locked_run|
        locked_run.update!(
          stage: advanced_stage(locked_run, "finalize"),
          status: "running",
          ai_finished_at: locked_run.ai_finished_at || at,
          ai_latency_ms: latency_ms || locked_run.ai_latency_ms || latency_from(locked_run.ai_started_at, at),
          ai_provider: summary["provider"].presence || locked_run.ai_provider,
          ai_model: summary["model"].presence || locked_run.ai_model,
          ai_fallback_provider: summary["fallback_provider"].presence || locked_run.ai_fallback_provider,
          ai_fallback_used: summary["fallback_used"] == true,
          ai_result_summary: summary
        )
        locked_run
      end
    end

    def record_final_result(summary, at: Time.current)
      with_mutable_run do |locked_run|
        locked_run.update!(
          stage: advanced_stage(locked_run, "completed"),
          status: "running",
          finalized_at: locked_run.finalized_at || at,
          final_result_summary: summary.to_h
        )
        locked_run
      end
    end

    def succeed(at: Time.current)
      terminate!("succeeded", at: at)
    end

    def fail(error_stage:, error_code:, error_message: nil, at: Time.current)
      terminate!(
        "failed",
        at: at,
        error_stage: error_stage,
        error_code: error_code,
        error_message: error_message
      )
    end

    def supersede(at: Time.current)
      terminate!("superseded", at: at)
    end

    def cancel(at: Time.current)
      terminate!("canceled", at: at)
    end

    private

    attr_reader :run

    def with_mutable_run
      run.with_lock do
        run.reload
        ensure_not_terminal!(run)
        yield run
      end
    end

    def terminate!(status, at:, error_stage: nil, error_code: nil, error_message: nil)
      run.with_lock do
        run.reload
        ensure_not_terminal!(run)

        run.update!(
          status: status,
          stage: terminal_stage_for(status, run),
          finished_at: at,
          finalized_at: run.finalized_at || (status == "succeeded" ? at : nil),
          total_latency_ms: run.total_latency_ms || latency_from(run.started_at, at),
          error_stage: terminal_error_value(status, error_stage || run.error_stage),
          error_code: terminal_error_value(status, error_code || run.error_code),
          error_message: terminal_error_value(status, safe_error_message(error_message || run.error_message)),
          expires_at: ReceiptAnalysisRun.default_expires_at_for(status: status, source: run.source, from: at)
        )
        run
      end
    end

    def normalize_stage!(stage, allowed:)
      normalized = stage.to_s
      raise InvalidTransition, "Unknown stage=#{stage}" unless allowed.include?(normalized)

      normalized
    end

    def ensure_not_terminal!(locked_run)
      return unless TERMINAL_STATUSES.include?(locked_run.status)

      raise TerminalRunError, "ReceiptAnalysisRun id=#{locked_run.id} is already terminal status=#{locked_run.status}"
    end

    def ensure_forward_transition!(locked_run, target_stage)
      current_index = stage_index(locked_run.stage)
      target_index = stage_index(target_stage)
      return if target_index >= current_index

      raise InvalidTransition, "Cannot move stage from #{locked_run.stage} to #{target_stage}"
    end

    def advanced_stage(locked_run, target_stage)
      stage_index(target_stage) > stage_index(locked_run.stage) ? target_stage : locked_run.stage
    end

    def stage_index(stage)
      ReceiptAnalysisRun::STAGES.index(stage.to_s) || -1
    end

    def stage_start_attributes(stage, at:, provider:, model:)
      case stage
      when "ocr"
        {
          ocr_started_at: at,
          ocr_provider: provider,
          ocr_model: model
        }.compact
      when "ai"
        {
          ai_started_at: at,
          ai_provider: provider,
          ai_model: model
        }.compact
      else
        {}
      end
    end

    def stage_finish_attributes(locked_run, stage, at:)
      case stage
      when "ocr"
        {
          ocr_finished_at: at,
          ocr_latency_ms: locked_run.ocr_latency_ms || latency_from(locked_run.ocr_started_at, at)
        }
      when "ai"
        {
          ai_finished_at: at,
          ai_latency_ms: locked_run.ai_latency_ms || latency_from(locked_run.ai_started_at, at)
        }
      when "finalize"
        {
          finalized_at: at
        }
      else
        {}
      end
    end

    def terminal_stage_for(status, locked_run)
      return "completed" if status == "succeeded"
      return "completed" if locked_run.stage == "completed"
      return "completed" if locked_run.status == "running" && locked_run.finalized_at.present?

      locked_run.stage
    end

    def terminal_error_value(status, value)
      status == "failed" ? value : nil
    end

    def latency_from(started_at, finished_at)
      return nil if started_at.blank? || finished_at.blank?

      ((finished_at - started_at) * 1000).round
    end

    def safe_error_message(value)
      return nil if value.blank?

      text = value.to_s
      return text if text.bytesize <= SnapshotBuilder::STRING_MAX_BYTES

      truncated = +""
      text.each_char do |char|
        break if truncated.bytesize + char.bytesize > SnapshotBuilder::STRING_MAX_BYTES

        truncated << char
      end
      truncated
    end
  end
end
