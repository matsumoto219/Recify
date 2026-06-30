class Admin::SecurityEventsController < Admin::BaseController
  def index
    @filters = filter_params
    @result = Admin.security_events(**@filters)
    @filter_options = Admin.security_event_filter_options
  end

  def show
    @record = Admin.security_event(id: params[:id])
    if @record.present? && @record[:ip_address].present?
      @ip_access_snapshot = ::Security.ip_access_snapshot(ip_address: @record[:ip_address])
      @ip_action_history = Admin.ip_actions(ip_address: @record[:ip_address], limit: 10)
    end
    @default_ip_block_expires_at = 24.hours.from_now
    return if @record.present?

    raise_not_found
  end

  def resolve
    update_status(:resolved)
  end

  def ignore
    update_status(:ignored)
  end

  def manual_ip_block
    execute_ip_access_operation("manual_ip_block")
  end

  def manual_ip_unblock
    execute_ip_access_operation("manual_ip_unblock")
  end

  def rack_attack_ban_reset
    execute_ip_access_operation("rack_attack_ip_ban_reset")
  end

  private

  def execute_ip_access_operation(operation)
    security_event = SecurityEvent.find_by(id: params[:id])
    raise_not_found if security_event.blank?

    unless admin_passkey_reauthenticated?
      redirect_to new_admin_passkey_reauthentication_path(return_to: admin_security_event_path(security_event)),
                  alert: t("admin.ip_access_operations.messages.reauthentication_required"),
                  status: :see_other
      return
    end

    if ip_access_operation_params[:reason].to_s.strip.blank?
      redirect_to admin_security_event_path(security_event), alert: t("admin.ip_access_operations.messages.reason_required"), status: :see_other
      return
    end

    if ip_access_operation_params[:confirmation].to_s.strip.blank?
      redirect_to admin_security_event_path(security_event), alert: t("admin.ip_access_operations.messages.confirmation_required"), status: :see_other
      return
    end

    result = SystemOperations.execute_ip_access_operation(
      operation: operation,
      ip_address: security_event.ip_address,
      actor: current_user,
      reason: ip_access_operation_params[:reason],
      request: request,
      reauthentication: admin_reauthentication_context,
      confirmation: ip_access_operation_params[:confirmation],
      source_security_event: security_event,
      expires_at: ip_access_operation_params[:expires_at],
      rack_attack_target: ip_access_operation_params[:rack_attack_target]
    )

    if result.success?
      redirect_to admin_security_event_path(security_event), notice: success_message(operation), status: :see_other
    else
      redirect_to admin_security_event_path(security_event), alert: failure_message(result), status: :see_other
    end
  end

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

  def ip_access_operation_params
    params.permit(:reason, :confirmation, :expires_at, :rack_attack_target)
  end

  def success_message(operation)
    t("admin.ip_access_operations.messages.success.#{operation}", default: t("admin.ip_access_operations.messages.success.default"))
  end

  def failure_message(result)
    t(
      "admin.ip_access_operations.messages.failure.#{result.error_code}",
      default: t("admin.ip_access_operations.messages.failure.default")
    )
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
