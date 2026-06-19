module SecurityEvents
  ADMIN_BURST_WINDOW = 1.hour
  ADMIN_BURST_THRESHOLD = 5
  RATE_LIMIT_METADATA_KEYS = %i[matched limit period retry_after].freeze

  class << self
    def detect(params:, max_detections: Detector::MAX_DETECTIONS, url_field_policy: UrlFieldPolicy.new)
      Detector.call(params: params, max_detections: max_detections, url_field_policy: url_field_policy)
    end

    def sanitize_metadata(value)
      MetadataSanitizer.call(value)
    end

    def sanitize_text(value)
      MetadataSanitizer.sanitize_text(value)
    end

    def record!(...)
      Recorder.call(...)
    end

    def cleanup_retention(...)
      RetentionCleanup.call(...)
    end

    def record_request_detections!(request:, params:, actor_user: nil)
      detect(params: params, url_field_policy: UrlFieldPolicy.for_request(request)).each do |detection|
        record!(
          event_type: detection.event_type,
          severity: detection.severity,
          request: request,
          actor_user: actor_user,
          field_name: detection.field_name,
          matched_rule: detection.matched_rule,
          payload_excerpt: detection.payload_excerpt,
          metadata: { source: "request_params" }
        )
      end
    rescue StandardError => e
      Rails.logger.warn("[SecurityEvents] request_detection_failed class=#{e.class.name}")
    end

    def record_rate_limit!(request:, matched_rule: nil, retry_after: nil, metadata: {})
      record!(
        event_type: "rate_limit_triggered",
        severity: "medium",
        request: request,
        ip_address: request_ip(request),
        user_agent: request_user_agent(request),
        request_id: request_id(request),
        path: request_path(request),
        method: request_method(request),
        matched_rule: matched_rule.presence || "rate_limit",
        metadata: filtered_rate_limit_metadata(metadata).merge(retry_after: retry_after).compact
      )
    rescue StandardError => e
      Rails.logger.warn("[SecurityEvents] rate_limit_record_failed class=#{e.class.name}")
    end

    def record_invalid_upload!(request:, actor_user:, file:, reason:, field_name: "receipt.image", metadata: {}, validation_errors: nil)
      file_metadata = {
        field_name: field_name,
        filename: upload_filename(file),
        content_type: upload_content_type(file),
        byte_size: upload_byte_size(file),
        extension: upload_extension(file),
        validation_errors: normalized_validation_errors(validation_errors)
      }.compact

      record!(
        event_type: "invalid_upload",
        severity: "medium",
        request: request,
        actor_user: actor_user,
        field_name: field_name,
        matched_rule: reason,
        payload_excerpt: file_metadata[:filename],
        metadata: metadata.merge(file_metadata).merge(reason: reason).compact
      )
    rescue StandardError => e
      Rails.logger.warn("[SecurityEvents] invalid_upload_record_failed class=#{e.class.name}")
    end

    def record_csrf_failure!(request:, actor_user: nil)
      record!(
        event_type: "csrf_failure",
        severity: "high",
        request: request,
        actor_user: actor_user,
        matched_rule: "invalid_authenticity_token",
        metadata: { source: "rails_csrf" }
      )
    rescue StandardError => e
      Rails.logger.warn("[SecurityEvents] csrf_record_failed class=#{e.class.name}")
    end

    def record_suspicious_error!(request:, actor_user:, status:)
      path = request_path(request).to_s
      return unless suspicious_error_path?(path, status)

      record!(
        event_type: "idor_attempt",
        severity: status.to_i == 403 ? "high" : "medium",
        request: request,
        actor_user: actor_user,
        matched_rule: "suspicious_#{status}",
        payload_excerpt: path,
        metadata: { status: status, source: "error_page" }
      )
    rescue StandardError => e
      Rails.logger.warn("[SecurityEvents] suspicious_error_record_failed class=#{e.class.name}")
    end

    def record_external_service_failure!(service:, error_code:, detail: nil, consecutive_failures: nil)
      return if consecutive_failures.to_i < 2

      normalized_detail = detail.respond_to?(:to_h) ? detail.to_h : {}
      severity = normalized_detail[:auth_error] || normalized_detail["auth_error"] ? "high" : "medium"
      severity = "high" if normalized_detail[:quota_exceeded] || normalized_detail["quota_exceeded"]

      record!(
        event_type: "external_service_repeated_failure",
        severity: severity,
        matched_rule: error_code,
        payload_excerpt: external_service_payload_excerpt(
          service: service,
          error_code: error_code,
          detail: normalized_detail
        ),
        metadata: {
          service: service,
          error_code: error_code,
          consecutive_failures: consecutive_failures,
          detail: normalized_detail
        }
      )
    rescue StandardError => e
      Rails.logger.warn("[SecurityEvents] external_service_record_failed class=#{e.class.name}")
    end

    def record_admin_audit_burst!(audit_log)
      action = audit_log.action.to_s
      event_type = admin_burst_event_type(action)
      return if event_type.blank?

      since = ADMIN_BURST_WINDOW.ago
      relation = AuditLog.where(actor_user_id: audit_log.actor_user_id, created_at: since..)
      relation = relation.where(action: action)
      action_count = relation.count
      return if action_count < ADMIN_BURST_THRESHOLD

      record!(
        event_type: event_type,
        severity: event_type == "admin_high_risk_burst" ? "high" : "medium",
        actor_user: audit_log.actor_user,
        ip_address: audit_log.ip_address,
        user_agent: audit_log.user_agent,
        request_id: audit_log.request_id,
        matched_rule: "admin_action_count_gte_#{ADMIN_BURST_THRESHOLD}",
        payload_excerpt: action,
        metadata: {
          action: action,
          count: action_count,
          window_seconds: ADMIN_BURST_WINDOW.to_i
        }
      )
    rescue StandardError => e
      Rails.logger.warn("[SecurityEvents] admin_audit_burst_record_failed class=#{e.class.name}")
    end

    private

    def filtered_rate_limit_metadata(metadata)
      return {} unless metadata.respond_to?(:to_h)

      metadata.to_h.symbolize_keys.slice(*RATE_LIMIT_METADATA_KEYS)
    end

    def external_service_payload_excerpt(service:, error_code:, detail:)
      [
        service,
        error_code,
        detail[:provider_error_code] || detail["provider_error_code"],
        detail[:provider_message_safe] || detail["provider_message_safe"]
      ].compact_blank.join(" ")
    end

    def request_ip(request)
      request.respond_to?(:remote_ip) ? request.remote_ip : request.try(:ip)
    end

    def request_user_agent(request)
      request.respond_to?(:user_agent) ? request.user_agent : request.try(:user_agent)
    end

    def request_id(request)
      return request.request_id if request.respond_to?(:request_id)
      return unless request.respond_to?(:get_header)

      request.get_header("action_dispatch.request_id")
    end

    def request_path(request)
      original_path = original_request_path(request)
      return original_path if original_path.present?

      request.respond_to?(:path) ? request.path : request.try(:path)
    end

    def request_method(request)
      request.respond_to?(:request_method) ? request.request_method : request.try(:request_method)
    end

    def upload_filename(file)
      file.respond_to?(:original_filename) ? file.original_filename.to_s : file.try(:filename).to_s
    end

    def upload_content_type(file)
      file.respond_to?(:content_type) ? file.content_type.to_s : nil
    end

    def upload_byte_size(file)
      file.respond_to?(:size) ? file.size : nil
    end

    def upload_extension(file)
      filename = upload_filename(file)
      return if filename.blank?

      File.extname(filename).presence
    end

    def normalized_validation_errors(errors)
      values = Array(errors).filter_map { |error| error.to_s.presence }.first(5)
      values.presence
    end

    def original_request_path(request)
      return unless request.respond_to?(:env)

      raw_path =
        request.env["action_dispatch.original_path"].presence ||
        request.env["action_dispatch.original_fullpath"].presence

      raw_path.to_s.split("?").first.presence
    end

    def suspicious_error_path?(path, status)
      return true if status.to_i == 403
      return false unless status.to_i == 404

      path.start_with?("/receipts/", "/admin/")
    end

    def admin_burst_event_type(action)
      case action
      when "system_settings.update"
        "system_settings_change_burst"
      when "admin.users.limit_update"
        "user_limits_override_burst"
      when *AuditLogs::RetentionPolicy::HIGH_RISK_ADMIN_ACTIONS
        "admin_high_risk_burst"
      end
    end
  end
end
