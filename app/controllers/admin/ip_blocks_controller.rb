class Admin::IpBlocksController < Admin::BaseController
  def index
    @filters = filter_params
    @result = Admin.ip_blocks(**@filters)
    @filter_options = Admin.ip_block_filter_options
  end

  def show
    @record = Admin.ip_block(id: params[:id])
    raise_not_found if @record.blank?

    @ip_access_snapshot = Security.ip_access_snapshot(ip_address: @record[:ip_address])
    @related_security_events = Admin.security_events(ip_address: @record[:ip_address], limit: 10)
  end

  def unblock
    block = SecurityIpBlock.includes(:source_security_event).find_by(id: params[:id])
    raise_not_found if block.blank?

    unless block.currently_effective?
      redirect_to admin_ip_block_path(block), alert: t("admin.ip_blocks.messages.not_unblockable"), status: :see_other
      return
    end

    unless admin_passkey_reauthenticated?
      redirect_to new_admin_passkey_reauthentication_path(return_to: admin_ip_block_path(block)),
                  alert: t("admin.ip_access_operations.messages.reauthentication_required"),
                  status: :see_other
      return
    end

    if unblock_params[:reason].to_s.strip.blank?
      redirect_to admin_ip_block_path(block), alert: t("admin.ip_access_operations.messages.reason_required"), status: :see_other
      return
    end

    if unblock_params[:confirmation].to_s.strip.blank?
      redirect_to admin_ip_block_path(block), alert: t("admin.ip_access_operations.messages.confirmation_required"), status: :see_other
      return
    end

    result = SystemOperations.execute_ip_access_operation(
      operation: "manual_ip_unblock",
      ip_address: block.ip_address.to_s,
      actor: current_user,
      reason: unblock_params[:reason],
      request: request,
      reauthentication: admin_reauthentication_context,
      confirmation: unblock_params[:confirmation],
      source_security_event: block.source_security_event
    )

    if result.success?
      redirect_to admin_ip_block_path(block), notice: t("admin.ip_blocks.messages.unblocked"), status: :see_other
    else
      redirect_to admin_ip_block_path(block), alert: failure_message(result), status: :see_other
    end
  end

  private

  def filter_params
    params.permit(
      :status,
      :ip_address,
      :created_by_id,
      :source_security_event_id,
      :expires_before,
      :expires_after,
      :created_from,
      :created_to,
      :limit,
      :offset
    ).to_h.each_with_object({}) do |(key, value), filters|
      filters[key.to_sym] = value if value.present?
    end
  end

  def unblock_params
    params.permit(:reason, :confirmation)
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
