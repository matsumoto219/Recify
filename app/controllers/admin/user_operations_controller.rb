class Admin::UserOperationsController < Admin::BaseController
  before_action :set_user

  def lock
    execute_user_operation("lock_user")
  end

  def unlock
    execute_user_operation("unlock_user")
  end

  private

  def set_user
    @user = User.find_by(id: params[:id])
    raise_not_found if @user.blank?
  end

  def execute_user_operation(operation)
    unless admin_passkey_reauthenticated?
      redirect_to new_admin_passkey_reauthentication_path(return_to: admin_user_path(@user)),
                  alert: "この操作にはパスキー再認証が必要です。",
                  status: :see_other
      return
    end

    if operation_params[:reason].to_s.strip.blank?
      redirect_to admin_user_path(@user), alert: "実行理由を入力してください。", status: :see_other
      return
    end

    if operation_params[:confirmation].to_s.strip.blank?
      redirect_to admin_user_path(@user), alert: "確認文字列を入力してください。", status: :see_other
      return
    end

    result = SystemOperations.execute_user_operation(
      operation: operation,
      user: @user,
      actor: current_user,
      reason: operation_params[:reason],
      request: request,
      reauthentication: admin_reauthentication_context,
      confirmation: operation_params[:confirmation]
    )

    if result.success?
      redirect_to admin_user_path(@user), notice: success_message(operation), status: :see_other
    else
      redirect_to admin_user_path(@user), alert: failure_message(result), status: :see_other
    end
  end

  def operation_params
    params.permit(:reason, :confirmation)
  end

  def success_message(operation)
    case operation
    when "lock_user"
      "ユーザーをロックしました。"
    when "unlock_user"
      "ユーザーのロックを解除しました。"
    else
      "管理操作を実行しました。"
    end
  end

  def failure_message(result)
    case result.error_code
    when "admin_target_forbidden"
      "管理者ユーザーにはこの操作を実行できません。"
    when "self_operation_forbidden"
      "自分自身にはこの操作を実行できません。"
    when "target_already_locked"
      "このユーザーはすでにロックされています。"
    when "target_not_locked"
      "このユーザーはロックされていません。"
    when "confirmation_required"
      "確認文字列が一致しません。"
    else
      "管理操作を実行できませんでした。"
    end
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
