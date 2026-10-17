module Receipts::RegistrationOperation
  private

  def issue_receipt_registration_token
    response.headers["Cache-Control"] = "no-store"
    @receipt_registration_token = Receipts::Registrations.issue_token(
      user: current_user,
      kind: action_name.in?(%w[new create]) ? "manual" : "upload"
    )
  end

  def with_receipt_registration_operation
    response.headers["Cache-Control"] = "no-store"
    result = Receipts::Registrations.with_operation(
      user: current_user,
      token: receipt_registration_token,
      kind: receipt_registration_kind,
      input: receipt_registration_input
    ) do |operation|
      @registration_operation = operation
      issue_receipt_registration_token
      yield
    end

    response.headers["X-Receipt-Registration-State"] = result.state
    if result.replayed?
      redirect_to receipts_path, notice: t("receipt_registration.submission.accepted"), status: :see_other
    elsif !performed?
      render_receipt_registration_unavailable(result.state)
    end
  end

  def receipt_registration_token
    request.request_parameters["receipt_registration_token"]
  end

  def receipt_registration_kind
    return "manual" if action_name == "create"

    batch_upload_requested? ? "batch_upload" : "upload"
  end

  def receipt_registration_input
    unless action_name == "create"
      return batch_upload_requested? ? uploaded_receipt_images : uploaded_receipt_image
    end

    context = Receipts::CalculationContext.verify(
      token: params[:receipt_calculation_context],
      user: current_user,
      receipt: Receipt.new(user: current_user)
    )
    {
      "receipt" => receipt_params.to_h,
      "calculation_settings" => receipt_calculation_controls,
      "calculation_defaults" => context&.defaults
    }
  end

  def render_receipt_registration_unavailable(state)
    state = state.in?(%w[expired conflict processing]) ? state : "invalid"
    status = state.in?(%w[conflict processing]) ? :conflict : :unprocessable_content
    @receipt_registration_token = receipt_registration_token if receipt_registration_token.is_a?(String)
    @receipt = current_user.receipts.new
    flash.now[:alert] = t("receipt_registration.submission.#{state}")

    if action_name == "create"
      prepare_receipt_form_presenter(submitted_params: receipt_params.to_h)
      render :new, status: status, formats: :html
    else
      set_external_service_states
      prepare_upload_page_presenter
      render :new_upload, status: status, formats: :html
    end
  end
end
