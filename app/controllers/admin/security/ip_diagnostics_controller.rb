class Admin::Security::IpDiagnosticsController < Admin::BaseController
  def show
    @snapshot = ::Security.request_ip_snapshot(request: request)
  end
end
