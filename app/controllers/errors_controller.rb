class ErrorsController < ApplicationController
  SERVICE_UNAVAILABLE_RETRY_AFTER_SECONDS = 300

  layout "error"
  helper_method :error_primary_label, :error_primary_path

  def not_found
    log_error_page(status: 404, level: :warn)
    render status: :not_found, formats: :html
  end

  def forbidden
    log_error_page(status: 403, level: :warn)
    render status: :forbidden, formats: :html
  end

  def unprocessable
    log_error_page(status: 422, level: :warn)
    render status: :unprocessable_content, formats: :html
  end

  def internal_server_error
    log_error_page(status: 500, level: :error)
    render status: :internal_server_error, formats: :html
  end

  def service_unavailable
    log_error_page(status: 503, level: :warn)
    set_service_unavailable_headers

    respond_to do |format|
      format.html { render status: :service_unavailable, formats: :html }
      format.json do
        render json: {
          error: t("errors.service_unavailable.title"),
          message: t("errors.service_unavailable.description"),
          status: Rack::Utils.status_code(:service_unavailable),
          retry_after: SERVICE_UNAVAILABLE_RETRY_AFTER_SECONDS
        }, status: :service_unavailable
      end
    end
  end

  private

  def set_service_unavailable_headers
    response.set_header("Cache-Control", "no-store")
    response.set_header("Retry-After", SERVICE_UNAVAILABLE_RETRY_AFTER_SECONDS.to_s)
  end

  def error_primary_label
    if user_signed_in?
      t("errors.common.signed_in_primary_cta")
    else
      t("errors.common.signed_out_primary_cta")
    end
  end

  def error_primary_path
    user_signed_in? ? receipts_path : new_user_session_path
  end

  def log_error_page(status:, level:)
    exception = request.env["action_dispatch.exception"]
    fields = {
      status: status,
      path: error_log_path,
      request_id: request.request_id,
      user_id: current_user&.id,
      exception_class: exception&.class&.name
    }
    fields[:exception_message] = truncated_exception_message(exception) if status == 500 && exception

    Rails.logger.public_send(level, "[ErrorPage] #{format_log_fields(fields)}")
  end

  def error_log_path
    raw_path =
      request.env["action_dispatch.original_path"].presence ||
      request.env["action_dispatch.original_fullpath"].presence ||
      request.path

    raw_path.to_s.split("?").first.presence || request.path
  end

  def format_log_fields(fields)
    fields.map do |key, value|
      "#{key}=#{log_value(value)}"
    end.join(" ")
  end

  def log_value(value)
    value.presence || "nil"
  end

  def truncated_exception_message(exception)
    message = exception.message.to_s.gsub(/\s+/, " ").strip
    message.length > 200 ? "#{message[0, 200]}..." : message
  end
end
