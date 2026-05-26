class Admin::SystemSettingsController < Admin::BaseController
  def index
    @result = Admin.system_settings(**filter_params)
  end

  def show
    @record = Admin.system_setting(key: params[:key])
    raise_not_found if @record.blank?
  end

  private

  def filter_params
    params.permit(:category, :editable, :risk_level).to_h.each_with_object({}) do |(key, value), filters|
      filters[key.to_sym] = value if value.present?
    end
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
