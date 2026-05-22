module Debug
  class ExternalServicesController < ApplicationController
    before_action :authenticate_user!
    before_action :ensure_debug_available!

    def update
      result = ExternalServices::DebugStateSwitcher.call(
        service: params[:service],
        state: params[:state],
        actor: current_user,
        reason: params[:reason],
        error_code: params[:error_code]
      )

      respond_to do |format|
        format.json { render json: { ok: true }.merge(result) }
        format.html { redirect_back fallback_location: new_upload_receipts_path, notice: notice_message(result) }
      end
    rescue ArgumentError => e
      respond_to do |format|
        format.json { render json: { ok: false, error: e.message }, status: :unprocessable_entity }
        format.html { redirect_back fallback_location: new_upload_receipts_path, alert: e.message }
      end
    rescue ExternalServices::DebugStateSwitcher::NotAvailableError
      head :not_found
    end

    private

    def ensure_debug_available!
      head :not_found unless ExternalServices::DebugStateSwitcher.available?
    end

    def notice_message(result)
      "External service #{result[:service]} switched to #{result[:requested_state]}."
    end
  end
end
