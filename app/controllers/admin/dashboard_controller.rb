class Admin::DashboardController < Admin::BaseController
  def show
    @dashboard = Admin.dashboard(admin_user: current_user)
  end
end
