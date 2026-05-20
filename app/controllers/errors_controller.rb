class ErrorsController < ApplicationController
  layout "error"
  helper_method :error_primary_label, :error_primary_path

  def not_found
    render status: :not_found, formats: :html
  end

  def unprocessable
    render status: :unprocessable_content, formats: :html
  end

  def internal_server_error
    render status: :internal_server_error, formats: :html
  end

  private

  def error_primary_label
    if user_signed_in?
      t("errors.common.signed_in_primary_cta")
    else
      t("errors.common.signed_out_primary_cta")
    end
  end

  def error_primary_path
    user_signed_in? ? receipts_path : new_user_session_path
  end
end
