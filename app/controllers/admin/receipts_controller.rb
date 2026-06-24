class Admin::ReceiptsController < Admin::BaseController
  before_action :set_receipt_record

  def show
  end

  def quarantine
    execute_receipt_moderation("quarantine")
  end

  def release
    execute_receipt_moderation("release")
  end

  def hard_delete
    execute_receipt_moderation("hard_delete")
  end

  private

  def set_receipt_record
    @record = Admin.receipt(public_id: params[:public_id])
    raise_not_found if @record.blank?

    @receipt = @record[:receipt]
  end

  def execute_receipt_moderation(operation)
    unless moderation_operation_allowed?(operation)
      redirect_to admin_receipt_path(@receipt), alert: t("admin.receipts.messages.not_available"), status: :see_other
      return
    end

    unless admin_passkey_reauthenticated?
      redirect_to new_admin_passkey_reauthentication_path(return_to: admin_receipt_path(@receipt)),
                  alert: t("admin.receipts.messages.reauthentication_required"),
                  status: :see_other
      return
    end

    if operation_params[:reason].to_s.strip.blank?
      redirect_to admin_receipt_path(@receipt), alert: t("admin.receipts.messages.reason_required"), status: :see_other
      return
    end

    if operation_params[:confirmation].to_s.strip.blank?
      redirect_to admin_receipt_path(@receipt), alert: t("admin.receipts.messages.confirmation_required"), status: :see_other
      return
    end

    result = SystemOperations.execute_receipt_moderation_operation(
      operation: operation,
      receipt: @receipt,
      actor: current_user,
      reason: operation_params[:reason],
      request: request,
      reauthentication: admin_reauthentication_context,
      confirmation: operation_params[:confirmation],
      source_security_event: source_security_event
    )

    if result.success?
      redirect_to success_redirect_path(operation), notice: success_message(operation), status: :see_other
    else
      redirect_to admin_receipt_path(@receipt), alert: failure_message(result), status: :see_other
    end
  end

  def operation_params
    params.permit(:reason, :confirmation, :source_security_event_id)
  end

  def moderation_operation_allowed?(operation)
    case operation
    when "quarantine"
      @receipt.moderation_active?
    when "release"
      @receipt.moderation_quarantined?
    when "hard_delete"
      @receipt.persisted?
    else
      false
    end
  end

  def source_security_event
    event_id = operation_params[:source_security_event_id].to_i
    return if event_id <= 0

    SecurityEvent.find_by(id: event_id)
  end

  def success_message(operation)
    t("admin.receipts.messages.success.#{operation}", default: t("admin.receipts.messages.success.default"))
  end

  def success_redirect_path(operation)
    return admin_user_path(@record.dig(:owner, :id)) if operation == "hard_delete" && @record.dig(:owner, :id).present?

    admin_receipt_path(@receipt)
  end

  def failure_message(result)
    t(
      "admin.receipts.messages.failure.#{result.error_code}",
      default: t("admin.receipts.messages.failure.default")
    )
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
