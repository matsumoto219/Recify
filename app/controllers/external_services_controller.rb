class ExternalServicesController < ApplicationController
  before_action :authenticate_user!

  def status
    render json: ExternalServices.status_snapshot(renderer: self)
  end
end
