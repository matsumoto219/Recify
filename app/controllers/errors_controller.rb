class ErrorsController < ApplicationController
  layout "error"

  def not_found
    render status: :not_found, formats: :html
  end

  def unprocessable
    render status: :unprocessable_content, formats: :html
  end

  def internal_server_error
    render status: :internal_server_error, formats: :html
  end
end
