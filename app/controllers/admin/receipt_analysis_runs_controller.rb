class Admin::ReceiptAnalysisRunsController < Admin::BaseController
  def index
    @result = Admin.receipt_analysis_runs(**filter_params)
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
      :limit,
      :offset
    ).to_h.symbolize_keys
  end
end
