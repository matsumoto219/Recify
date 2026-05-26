class Admin::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  private

  def require_admin!
    return if current_user&.admin?

    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
