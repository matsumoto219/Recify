class Admin::ReceiptAnalysisRunsController < Admin::BaseController
  def index
    @filters = filter_params
    @result = Admin.receipt_analysis_runs(**@filters)
  end

  def show
    @result = Admin.receipt_analysis_runs(run_key: params[:run_key], limit: 1)
    @record = @result.records.first
    return if @record.present?

    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end

  private

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
end
