class ExternalServicesController < ApplicationController
  before_action :authenticate_user!

  def status
    render json: ExternalServices::StatusSnapshot.call(renderer: self)
  end
end
