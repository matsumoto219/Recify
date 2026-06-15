class Admin::SecurityEventsController < Admin::BaseController
  def index
    @filters = filter_params
    @result = Admin.security_events(**@filters)
    @filter_options = Admin.security_event_filter_options
  end

  def show
    @record = Admin.security_event(id: params[:id])
    return if @record.present?

    raise_not_found
  end

  def resolve
    update_status(:resolved)
  end

  def ignore
    update_status(:ignored)
  end

  private

  def update_status(status)
    security_event = SecurityEvent.find_by(id: params[:id])
    raise_not_found if security_event.blank?

    result = Admin.update_security_event_status(
      security_event: security_event,
      status: status,
      actor: current_user,
      request: request
    )

    if result.updated?
      redirect_to admin_security_event_path(security_event), notice: t("admin.security_events.messages.#{status}"), status: :see_other
    else
      redirect_to admin_security_event_path(security_event), alert: t("admin.security_events.messages.update_failed"), status: :see_other
    end
  end

  def filter_params
    params.permit(
      :actor_user_id,
      :event_type,
      :severity,
      :ip_address,
      :request_id,
      :path,
      :matched_rule,
      :state,
      :created_from,
      :created_to,
      :limit,
      :offset
    ).to_h.each_with_object({}) do |(key, value), filters|
      filters[key.to_sym] = value if value.present?
    end
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
