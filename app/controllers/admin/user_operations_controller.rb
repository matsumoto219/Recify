class Admin::UserOperationsController < Admin::BaseController
  before_action :set_user

  def lock
    execute_user_operation("lock_user")
  end

  def unlock
    execute_user_operation("unlock_user")
  end

  def force_passkey_reset
    execute_user_operation("force_passkey_reset")
  end

  def force_two_factor_reset
    execute_user_operation("force_two_factor_reset")
  end

  def force_password_reset_instruction
    execute_user_operation("force_password_reset_instruction")
  end

  def admin_email_change_recovery
    execute_user_operation("admin_email_change_recovery")
  end

  def revoke_sessions
    execute_user_operation("revoke_sessions")
  end

  def delete
    execute_user_operation("delete_user")
  end

  private

  def set_user
    @user = User.find_by(id: params[:id])
    raise_not_found if @user.blank?
  end

  def execute_user_operation(operation)
    unless admin_passkey_reauthenticated?
      redirect_to new_admin_passkey_reauthentication_path(return_to: admin_user_path(@user)),
                  alert: t("admin.user_operations.messages.reauthentication_required"),
                  status: :see_other
      return
    end

    if operation_params[:reason].to_s.strip.blank?
      redirect_to admin_user_path(@user), alert: t("admin.user_operations.messages.reason_required"), status: :see_other
      return
    end

    if operation_params[:confirmation].to_s.strip.blank?
      redirect_to admin_user_path(@user), alert: t("admin.user_operations.messages.confirmation_required"), status: :see_other
      return
    end

    result = SystemOperations.execute_user_operation(
      operation: operation,
      user: @user,
      actor: current_user,
      reason: operation_params[:reason],
      request: request,
      reauthentication: admin_reauthentication_context,
      confirmation: confirmation_for(operation)
    )

    if result.success?
      redirect_to success_redirect_path(operation), notice: success_message(operation), status: :see_other
    else
      redirect_to admin_user_path(@user), alert: failure_message(result), status: :see_other
    end
  end

  def operation_params
    params.permit(:reason, :confirmation, :confirmation_email, :new_email)
  end

  def confirmation_for(operation)
    return recovery_email_confirmation if operation == "admin_email_change_recovery"
    return operation_params[:confirmation] unless operation == "delete_user"

    {
      text: operation_params[:confirmation],
      email: operation_params[:confirmation_email]
    }
  end

  def recovery_email_confirmation
    {
      text: operation_params[:confirmation],
      new_email: operation_params[:new_email]
    }
  end

  def success_redirect_path(operation)
    return admin_users_path if operation == "delete_user"

    admin_user_path(@user)
  end

  def success_message(operation)
    t("admin.user_operations.messages.success.#{operation}", default: t("admin.user_operations.messages.success.default"))
  end

  def failure_message(result)
    t(
      "admin.user_operations.messages.failure.#{result.error_code}",
      default: t("admin.user_operations.messages.failure.default")
    )
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
