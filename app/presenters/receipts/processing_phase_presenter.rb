module Receipts
  class ProcessingPhasePresenter
    Step = Struct.new(:key, :label, :state, keyword_init: true)

    STEP_KEYS = %i[uploaded ocr ai review].freeze
    FINAL_RECEIPT_PHASES = {
      "review_needed" => :review_needed,
      "completed" => :completed,
      "failed" => :failed
    }.freeze
    PHASE_STEPS = {
      queued: 0,
      processing: 0,
      ocr: 1,
      organizing: 1,
      ai: 2,
      finalize: 3,
      review_needed: 3,
      completed: 3,
      failed: 3
    }.freeze
    PHASE_ORDER = {
      queued: 0,
      processing: 0,
      ocr: 1,
      organizing: 2,
      ai: 3,
      finalize: 4,
      review_needed: 5,
      completed: 5,
      failed: 5
    }.freeze

    attr_reader :receipt, :analysis_run

    def initialize(receipt:, analysis_run: nil)
      @receipt = receipt
      @analysis_run = analysis_run || (processing? ? latest_active_analysis_run : nil)
    end

    def key
      @key ||= phase_key
    end

    def label
      I18n.t("receipt_cards.processing_phase.#{key}.label")
    end

    def description
      I18n.t("receipt_cards.processing_phase.#{key}.description")
    end

    def icon
      I18n.t("receipt_cards.processing_phase.#{key}.icon")
    end

    def css_class
      "receipt-processing-phase-#{key.to_s.dasherize}"
    end

    def processing?
      receipt.status.to_s == "processing"
    end

    def ocr?
      key == :ocr
    end

    def ai?
      key == :ai
    end

    def step_index
      PHASE_STEPS.fetch(key, 0)
    end

    def phase_order
      PHASE_ORDER.fetch(key, 0)
    end

    def state_revision
      timestamp = [ receipt.updated_at, analysis_run&.updated_at ].compact.max

      (timestamp.to_r * 1_000_000).to_i
    end

    def terminal?
      FINAL_RECEIPT_PHASES.key?(receipt.status.to_s)
    end

    def steps
      STEP_KEYS.each_with_index.map do |step_key, index|
        Step.new(
          key: step_key,
          label: I18n.t("receipt_cards.processing_steps.#{step_key}"),
          state: step_state(index)
        )
      end
    end

    private

    def phase_key
      final_key = FINAL_RECEIPT_PHASES[receipt.status.to_s]
      return final_key if final_key
      return :processing unless processing?
      return :processing unless analysis_run

      return :queued if analysis_run.status.to_s == "queued" || analysis_run.stage.to_s == "queued"
      return :ocr if ocr_processing?
      return :ai if ai_processing?
      return :finalize if finalize_processing?
      return :organizing if ocr_finished?

      :processing
    end

    def latest_active_analysis_run
      relation = receipt.receipt_analysis_runs
      runs = relation.loaded? ? relation.select(&:active?) : relation.active
      runs.max_by(&:created_at)
    end

    def ocr_processing?
      analysis_run.stage.to_s == "ocr" ||
        (analysis_run.ocr_started_at.present? && analysis_run.ocr_finished_at.blank?)
    end

    def ai_processing?
      analysis_run.ai_started_at.present? && analysis_run.ai_finished_at.blank?
    end

    def finalize_processing?
      %w[finalize completed].include?(analysis_run.stage.to_s) ||
        analysis_run.finalized_at.present?
    end

    def ocr_finished?
      analysis_run.ocr_finished_at.present? || analysis_run.stage.to_s == "ocr_validation"
    end

    def step_state(index)
      return "done" if index < step_index
      return "active" if index == step_index

      "pending"
    end
  end
end
