class Admin::ExternalServicesController < Admin::BaseController
  def status
    external_services = ExternalServices.status_snapshot(include_details: true)
    html = render_to_string(
      partial: "admin/dashboard/external_services_card",
      formats: [ :html ],
      locals: { external_services: external_services }
    )

    render json: { html: html }
  end
end
