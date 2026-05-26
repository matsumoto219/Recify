class Admin::SystemOperationsController < Admin::BaseController
  def show
    @dashboard = Admin.system_operations_dashboard
  end
end
