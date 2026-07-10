class Admin::SystemSettingsController < Admin::BaseController
  def index
    @result = Admin.system_settings(**filter_params)
  end

  def show
    @record = Admin.system_setting(key: params[:key])
    raise_not_found if @record.blank?
    prepare_form_presenter
  end

  def update
    @record = Admin.system_setting(key: params[:key])
    raise_not_found if @record.blank?

    unless admin_passkey_reauthenticated?
      redirect_to new_admin_passkey_reauthentication_path(return_to: admin_system_setting_path(@record[:key])),
                  alert: t("admin.system_settings.messages.reauthentication_required"),
                  status: :see_other
      return
    end

    if update_params[:reason].to_s.strip.blank?
      render_update_failure(t("admin.system_settings.messages.reason_required"))
      return
    end

    result = SystemOperations.update_setting(
      key: @record[:key],
      value: update_params[:value],
      actor: current_user,
      reason: update_params[:reason],
      request: request,
      reauthentication: admin_reauthentication_context,
      confirmation: update_params[:confirm]
    )

    if result.success?
      redirect_to admin_system_setting_path(@record[:key]),
                  notice: t("admin.system_settings.messages.updated"),
                  status: :see_other
    else
      render_update_failure(failure_message(result))
    end
  end

  private

  def filter_params
    params.permit(:category, :editable, :risk_level).to_h.each_with_object({}) do |(key, value), filters|
      filters[key.to_sym] = value if value.present?
    end
  end

  def update_params
    params.permit(:value, :reason, :confirm)
  end

  def failure_message(result)
    t(
      "admin.system_settings.messages.failure.#{result.error_code}",
      default: t("admin.system_settings.messages.failed", error_code: result.error_code)
    )
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end

  def prepare_form_presenter(form_values: {})
    @form_presenter = Admin::SystemSettingFormPresenter.new(
      record: @record,
      reauthenticated: admin_passkey_reauthenticated?,
      form_values: form_values
    )
  end

  def render_update_failure(message)
    @form_values = update_params.to_h.symbolize_keys.slice(:value, :reason, :confirm)
    prepare_form_presenter(form_values: @form_values)
    flash.now[:alert] = message
    render :show, status: :unprocessable_content
  end
end
