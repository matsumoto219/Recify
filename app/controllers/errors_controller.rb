class ErrorsController < ApplicationController
  layout "error"

  def not_found
    render status: :not_found
  end

  def unprocessable
    render status: :unprocessable_content
  end

  def internal_server_error
    render status: :internal_server_error
  end
end
