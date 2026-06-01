class Admin::ReceiptAnalysisRunsController < Admin::BaseController
  RETRY_TYPES = Analysis.retry_types.freeze
  RETRY_CONFIRMATION_TEXT = Analysis.retry_confirmation_text

  helper_method :admin_retry_enabled?, :admin_retry_reauthentication_required?, :retry_confirmation_text

  def index
    @filters = filter_params
    @result = Admin.receipt_analysis_runs(**@filters)
  end

  def show
    @result = Admin.receipt_analysis_runs(run_key: params[:run_key], limit: 1, include_retry_options: true)
    @record = @result.records.first
    return if @record.present?

    raise_not_found
  end

  def retry
    @result = Admin.receipt_analysis_runs(run_key: params[:run_key], limit: 1, include_retry_options: true)
    @record = @result.records.first
    raise_not_found if @record.blank?

    unless admin_retry_enabled?
      redirect_to new_admin_passkey_reauthentication_path(return_to: admin_receipt_analysis_run_path(@record[:run_key])),
                  alert: t("admin.receipt_analysis_runs.messages.reauthentication_required"),
                  status: :see_other
      return
    end

    retry_type = params[:retry_kind].presence || params[:retry_type].to_s
    reason = params[:reason].to_s.strip

    unless RETRY_TYPES.include?(retry_type)
      redirect_to admin_receipt_analysis_run_path(params[:run_key]), alert: t("admin.receipt_analysis_runs.messages.retry_type_required")
      return
    end

    if reason.blank?
      redirect_to admin_receipt_analysis_run_path(params[:run_key]), alert: t("admin.receipt_analysis_runs.messages.reason_required")
      return
    end

    unless params[:confirmation].to_s.strip == RETRY_CONFIRMATION_TEXT
      redirect_to admin_receipt_analysis_run_path(params[:run_key]), alert: t("admin.receipt_analysis_runs.messages.confirmation_required")
      return
    end

    retry_attributes = {
      receipt: @record[:receipt],
      parent_run: @record[:run],
      actor: current_user,
      retry_type: retry_type,
      reason: reason,
      request: request,
      reauthentication: admin_reauthentication_context,
      confirmation: params[:confirmation]
    }

    result = Analysis.retry_receipt_analysis(**retry_attributes)

    if result.success?
      redirect_to admin_receipt_analysis_run_path(result.run.run_key), notice: t("admin.receipt_analysis_runs.messages.accepted")
    else
      redirect_to admin_receipt_analysis_run_path(params[:run_key]), alert: t("admin.receipt_analysis_runs.messages.failed", error_code: result.error_code)
    end
  end

  private

  def admin_retry_enabled?
    current_user.passkeys.exists? && admin_passkey_reauthenticated?
  end

  def admin_retry_reauthentication_required?
    !admin_retry_enabled?
  end

  def retry_confirmation_text
    RETRY_CONFIRMATION_TEXT
  end

  def filter_params
    params.permit(
      :receipt_public_id,
      :user_id,
      :status,
      :stage,
      :error_code,
      :source,
      :receipt_status,
      :needs_attention,
      :run_key,
      :limit,
      :offset
    ).to_h.each_with_object({}) do |(key, value), filters|
      next if value.blank?

      filters[key.to_sym] = value
    end
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
