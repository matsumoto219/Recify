class Admin::ReceiptAnalysisCleanupController < Admin::BaseController
  helper_method :cleanup_execution_enabled?

  def show
    @preview = Admin.receipt_analysis_cleanup_preview(**preview_params)
  rescue Admin::ReceiptAnalysisCleanupInvalidParameter
    @preview_input_values = preview_params.slice(:stale_limit, :retention_limit)
    @preview = Admin.receipt_analysis_cleanup_preview
    flash.now[:alert] = t("admin.receipt_analysis_cleanup.messages.invalid_limit")
    render :show, status: :unprocessable_content
  end

  def execute_stale
    execute_cleanup(
      operation: "stale_cleanup",
      cutoff: execution_params[:stale_cutoff],
      limit: execution_params[:stale_limit],
      confirmation_valid: ActiveModel::Type::Boolean.new.cast(execution_params[:confirm])
    )
  end

  def execute_retention
    execute_cleanup(
      operation: "retention_cleanup",
      cutoff: execution_params[:retention_cutoff],
      limit: execution_params[:retention_limit],
      confirmation_valid: ActiveModel::Type::Boolean.new.cast(execution_params[:confirm]) &&
        execution_params[:confirmation_text].to_s == "DELETE EXPIRED RUNS"
    )
  end

  private

  def execute_cleanup(operation:, cutoff:, limit:, confirmation_valid:)
    unless cleanup_execution_enabled?
      redirect_to new_admin_passkey_reauthentication_path(return_to: admin_receipt_analysis_cleanup_path),
                  alert: t("admin.receipt_analysis_cleanup.messages.reauthentication_required"),
                  status: :see_other
      return
    end

    if execution_params[:reason].to_s.strip.blank?
      redirect_to admin_receipt_analysis_cleanup_path(redirect_preview_params),
                  alert: t("admin.receipt_analysis_cleanup.messages.reason_required"),
                  status: :see_other
      return
    end

    unless confirmation_valid
      redirect_to admin_receipt_analysis_cleanup_path(redirect_preview_params),
                  alert: t("admin.receipt_analysis_cleanup.messages.confirmation_required"),
                  status: :see_other
      return
    end

    result = SystemOperations.execute_receipt_analysis_cleanup(
      operation: operation,
      actor: current_user,
      reason: execution_params[:reason],
      cutoff: cutoff,
      limit: limit,
      request: request,
      reauthentication: admin_reauthentication_context
    )

    if result.success?
      redirect_to admin_receipt_analysis_cleanup_path(redirect_preview_params),
                  notice: cleanup_notice(operation, result.cleanup_result),
                  status: :see_other
    else
      redirect_to admin_receipt_analysis_cleanup_path(redirect_preview_params),
                  alert: t("admin.receipt_analysis_cleanup.messages.failed", error_code: result.error_code),
                  status: :see_other
    end
  end

  def cleanup_execution_enabled?
    current_user.passkeys.exists? && admin_passkey_reauthenticated?
  end

  def preview_params
    params.permit(
      :stale_cutoff,
      :stale_limit,
      :retention_cutoff,
      :retention_limit
    ).to_h.symbolize_keys
  end

  def execution_params
    @execution_params ||= params.permit(
      :stale_cutoff,
      :stale_limit,
      :retention_cutoff,
      :retention_limit,
      :reason,
      :confirm,
      :confirmation_text
    ).to_h.symbolize_keys
  end

  def redirect_preview_params
    execution_params.slice(
      :stale_cutoff,
      :stale_limit,
      :retention_cutoff,
      :retention_limit
    ).compact_blank
  end

  def cleanup_notice(operation, cleanup_result)
    if operation == "stale_cleanup"
      t(
        "admin.receipt_analysis_cleanup.messages.stale_executed",
        failed_count: cleanup_result[:failed_count],
        canceled_count: cleanup_result[:canceled_count],
        stuck_processing_failed_count: cleanup_result[:stuck_processing_failed_count].to_i
      )
    else
      t("admin.receipt_analysis_cleanup.messages.retention_executed", deleted_count: cleanup_result[:deleted_count])
    end
  end
end
