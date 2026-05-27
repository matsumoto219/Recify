class Admin::UserLimitOverridesController < Admin::BaseController
  USER_LIMIT_CONFIRMATION_TEXT = SystemOperations::UserLimitUpdateExecutor::CONFIRMATION_TEXT

  before_action :set_user

  def create
    unless admin_passkey_reauthenticated?
      redirect_to new_admin_passkey_reauthentication_path(return_to: admin_user_path(@user)),
                  alert: t("admin.user_limit_overrides.messages.reauthentication_required"),
                  status: :see_other
      return
    end

    if limit_params[:reason].to_s.strip.blank?
      redirect_to admin_user_path(@user), alert: t("admin.user_limit_overrides.messages.reason_required"), status: :see_other
      return
    end

    if limit_params[:confirmation].to_s.strip.blank?
      redirect_to admin_user_path(@user), alert: t("admin.user_limit_overrides.messages.confirmation_required"), status: :see_other
      return
    end

    result = SystemOperations.update_user_limit(
      user: @user,
      key: limit_params[:key],
      value: limit_params[:value],
      enabled: limit_params[:enabled],
      expires_at: limit_params[:expires_at],
      actor: current_user,
      reason: limit_params[:reason],
      request: request,
      reauthentication: admin_reauthentication_context,
      confirmation: limit_params[:confirmation]
    )

    if result.success?
      redirect_to admin_user_path(@user), notice: t("admin.user_limit_overrides.messages.success"), status: :see_other
    else
      redirect_to admin_user_path(@user), alert: failure_message(result), status: :see_other
    end
  end

  private

  def set_user
    @user = User.find_by(id: params[:id])
    raise_not_found if @user.blank?
  end

  def limit_params
    params.permit(:key, :value, :enabled, :expires_at, :reason, :confirmation)
  end

  def failure_message(result)
    t(
      "admin.user_limit_overrides.messages.failure.#{result.error_code}",
      default: t("admin.user_limit_overrides.messages.failure.default")
    )
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
