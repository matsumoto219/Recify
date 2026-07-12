class Admin::DashboardController < Admin::BaseController
  def show
    @dashboard = Admin.dashboard(admin_user: current_user)
    @external_services = ExternalServices::StatusPresenter.call(
      snapshot: @dashboard.external_services,
      view_context: self,
      render_badges: false
    )
  end
end
