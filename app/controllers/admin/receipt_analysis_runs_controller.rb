class Admin::ReceiptAnalysisRunsController < Admin::BaseController
  RETRY_TYPES = Analysis::RetryService::RETRY_TYPES.freeze

  helper_method :admin_retry_enabled?

  def index
    @filters = filter_params
    @result = Admin.receipt_analysis_runs(**@filters)
  end

  def show
    @result = Admin.receipt_analysis_runs(run_key: params[:run_key], limit: 1)
    @record = @result.records.first
    return if @record.present?

    raise_not_found
  end

  def retry
    raise_not_found unless admin_retry_enabled?

    @result = Admin.receipt_analysis_runs(run_key: params[:run_key], limit: 1)
    @record = @result.records.first
    raise_not_found if @record.blank?

    retry_type = params[:retry_type].to_s
    reason = params[:reason].to_s.strip

    unless RETRY_TYPES.include?(retry_type)
      redirect_to admin_receipt_analysis_run_path(params[:run_key]), alert: "Invalid retry type."
      return
    end

    if reason.blank?
      redirect_to admin_receipt_analysis_run_path(params[:run_key]), alert: "Retry reason is required."
      return
    end

    result = Analysis::RetryService.call(
      receipt: @record[:receipt],
      parent_run: @record[:run],
      actor: current_user,
      retry_type: retry_type,
      reason: reason,
      request: request
    )

    if result.success?
      redirect_to admin_receipt_analysis_run_path(result.run.run_key), notice: "Retry enqueued: #{retry_type}"
    else
      redirect_to admin_receipt_analysis_run_path(params[:run_key]), alert: "Retry failed: #{result.error_code}"
    end
  end

  private

  def admin_retry_enabled?
    # TODO: passkey再認証実装後にproduction retry actionを解禁する。
    # high-risk admin action requires passkey reauthentication.
    Rails.env.development? || Rails.env.test?
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
