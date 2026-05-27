class Admin::ContactRequestsController < Admin::BaseController
  def index
    @filters = filter_params
    @result = Admin.contact_requests(**@filters)
  end

  def show
    @record = Admin.contact_request(id: params[:id])
    raise_not_found if @record.blank?
  end

  def update
    contact_request = ContactRequest.find(params[:id])
    result = Admin::ContactRequestStatusUpdater.call(
      contact_request: contact_request,
      status: status_param,
      actor: current_user,
      request: request
    )

    if result.success?
      redirect_to admin_contact_request_path(contact_request),
                  notice: t("admin.contact_requests.messages.status_updated"),
                  status: :see_other
    else
      redirect_to admin_contact_request_path(contact_request),
                  alert: t("admin.contact_requests.messages.status_update_failed"),
                  status: :see_other
    end
  end

  private

  def filter_params
    params.permit(
      :status,
      :category,
      :source,
      :email_digest,
      :user_id,
      :request_uid,
      :created_from,
      :created_to,
      :limit,
      :offset
    ).to_h.each_with_object({}) do |(key, value), filters|
      filters[key.to_sym] = value if value.present?
    end
  end

  def status_param
    params.require(:contact_request).permit(:status).fetch(:status)
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
