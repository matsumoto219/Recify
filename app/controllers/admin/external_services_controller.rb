class Admin::ExternalServicesController < Admin::BaseController
  def status
    external_services = ExternalServices::StatusPresenter.call(
      snapshot: ExternalServices.status_snapshot(include_details: true),
      view_context: self,
      render_badges: false
    )
    html = render_to_string(
      partial: "admin/dashboard/external_services_card",
      formats: [ :html ],
      locals: { external_services: external_services }
    )

    render json: { html: html }
  end
end
