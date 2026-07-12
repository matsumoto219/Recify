class Receipts::Processing::AdminRetryPolicy
  RETRY_TYPES = %w[
    full_reanalyze
    ocr_retry
    ai_retry
    finalize_retry
  ].freeze
  ACTIVE_RUN_UNSET = Object.new.freeze

  Eligibility = Struct.new(:retry_options, keyword_init: true)
  Decision = Data.define(:disabled_reason, :active_run, :snapshot_requirements) do
    def possible?
      disabled_reason.blank?
    end
  end

  class << self
    def eligibility(receipt:, parent_run:)
      active_run = find_active_run(receipt)

      Eligibility.new(
        retry_options: RETRY_TYPES.map do |retry_type|
          decision = decision(receipt: receipt, parent_run: parent_run, retry_type: retry_type, active_run: active_run)
          {
            type: retry_type,
            possible: decision.possible?,
            disabled_reason: decision.disabled_reason
          }
        end
      )
    end

    def decision(receipt:, parent_run:, retry_type:, active_run: ACTIVE_RUN_UNSET)
      new(
        receipt: receipt,
        parent_run: parent_run,
        retry_type: retry_type,
        active_run: active_run
      ).decision
    end

    private

    def find_active_run(receipt)
      receipt&.receipt_analysis_runs&.active&.order(created_at: :desc)&.first
    end
  end

  def initialize(receipt:, parent_run:, retry_type:, active_run: ACTIVE_RUN_UNSET)
    @receipt = receipt
    @parent_run = parent_run
    @retry_type = retry_type.to_s
    @active_run = active_run unless active_run.equal?(ACTIVE_RUN_UNSET)
  end

  def decision
    Decision.new(
      disabled_reason: disabled_reason,
      active_run: active_run,
      snapshot_requirements: finalize_retry_snapshot_requirements
    )
  end

  private

  attr_reader :receipt, :parent_run, :retry_type

  def disabled_reason
    return "parent_run_receipt_mismatch" if parent_run.present? && parent_run.receipt_id != receipt&.id
    return "active_run_exists" if active_run.present?

    case retry_type
    when "full_reanalyze", "ocr_retry"
      return "image_missing" unless receipt&.image&.attached?
      return "ocr_unavailable" if ExternalServices.down?(:ocr)
    when "ai_retry"
      return "parent_run_missing" if parent_run.blank?
      return "ocr_snapshot_missing" if parent_run.ocr_result_snapshot.blank?
      return "ai_unavailable" if ExternalServices.down?(:ai)
    when "finalize_retry"
      return "parent_run_missing" if parent_run.blank?
      return "finalize_decision_missing" if parent_finalize_decision.blank?

      requirements = finalize_retry_snapshot_requirements
      return "ocr_snapshot_missing" if requirements[:ocr] && parent_run.ocr_result_snapshot.blank?
      return "ai_snapshot_missing" if requirements[:ai] && parent_run.ai_normalized_result_snapshot.blank?
    end

    nil
  end

  def active_run
    return @active_run if instance_variable_defined?(:@active_run)
    return unless receipt

    @active_run = receipt.receipt_analysis_runs.active.order(created_at: :desc).first
  end

  def parent_finalize_decision
    @parent_finalize_decision ||= Receipts::Processing.finalize_decision_from_snapshot(
      parent_run&.metadata.to_h["finalize_decision"]
    )
  end

  def finalize_retry_snapshot_requirements
    return { ocr: false, ai: false } unless retry_type == "finalize_retry"

    case parent_finalize_decision&.finalize_strategy.to_s
    when "ai_success"
      { ocr: true, ai: true }
    when "ai_fallback", "ocr_only"
      { ocr: true, ai: false }
    else
      { ocr: false, ai: false }
    end
  end
end
