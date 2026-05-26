class Admin::ReceiptAnalysisCleanupController < Admin::BaseController
  def show
    @preview = Admin.receipt_analysis_cleanup_preview(**preview_params)
  end

  private

  def preview_params
    params.permit(
      :stale_cutoff,
      :stale_limit,
      :retention_cutoff,
      :retention_limit
    ).to_h.symbolize_keys
  end
end
