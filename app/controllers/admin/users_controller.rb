class Admin::UsersController < Admin::BaseController
  USER_LIMIT_CONFIRMATION_TEXT = SystemOperations.user_limit_update_confirmation_text

  helper_method :user_limit_confirmation_text

  def index
    @filters = filter_params
    @result = Admin.users(**@filters)
  end

  def show
    @record = Admin.user(id: params[:id])
    raise_not_found if @record.blank?

    @audit_result = Admin.audit_logs(actor_user_id: @record[:id], limit: 10)
    @security_events_result = Admin.security_events(actor_user_id: @record[:id], limit: 10)
  end

  private

  def filter_params
    params.permit(
      :email,
      :admin,
      :guest,
      :confirmed,
      :locked,
      :has_passkey,
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

  def user_limit_confirmation_text
    USER_LIMIT_CONFIRMATION_TEXT
  end
end
