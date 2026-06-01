class Admin::AuditLogsController < Admin::BaseController
  def index
    @filters = filter_params
    @result = Admin.audit_logs(**@filters)
    @filter_options = Admin.audit_log_filter_options
  end

  def show
    @result = Admin.audit_logs(id: params[:id], limit: 1)
    @record = @result.records.first
    return if @record.present?

    raise_not_found
  end

  private

  def filter_params
    params.permit(
      :actor_user_id,
      :actor_kind,
      :audit_action,
      :outcome,
      :target_uid,
      :request_id,
      :error_code,
      :created_from,
      :created_to,
      :limit,
      :offset
    ).to_h.each_with_object({}) do |(key, value), filters|
      next if value.blank?

      if key == "audit_action"
        filters[:action] = value
      else
        filters[key.to_sym] = value
      end
    end
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
