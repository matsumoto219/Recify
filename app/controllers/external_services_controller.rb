class ExternalServicesController < ApplicationController
  before_action :authenticate_user!

  def status
    snapshot = ExternalServices.status_snapshot(include_details: false)
    payload = ExternalServices::StatusPresenter.call(
      snapshot: snapshot,
      view_context: self,
      render_badges: true
    )

    render json: payload
  end
end
