module SystemSettings
  class Definitions
    ALL = [
      Definition.new(
        key: "feature.receipt_image_preprocess_enabled",
        category: "feature_flag",
        value_type: "boolean",
        default: false,
        editable: true,
        risk_level: "medium"
      ),
      Definition.new(
        key: "feature.receipt_logo_display_enabled",
        category: "feature_flag",
        value_type: "boolean",
        default: false,
        editable: true,
        risk_level: "low"
      ),
      Definition.new(
        key: "analysis_artifact.ocr_raw_response_capture_enabled",
        category: "analysis_artifact",
        value_type: "boolean",
        default: false,
        editable: true,
        risk_level: "high"
      ),
      Definition.new(
        key: "feature.receipt_image_preprocess",
        category: "feature_flag",
        value_type: "feature_flag",
        default: {
          "enabled" => false,
          "rollout_percentage" => 0,
          "user_allowlist" => []
        },
        editable: true,
        risk_level: "medium"
      ),
      Definition.new(
        key: "feature.receipt_logo_display",
        category: "feature_flag",
        value_type: "feature_flag",
        default: {
          "enabled" => false,
          "rollout_percentage" => 0,
          "user_allowlist" => []
        },
        editable: true,
        risk_level: "low"
      ),
      Definition.new(
        key: "operations.ocr_enabled",
        category: "operation",
        value_type: "boolean",
        default: true,
        editable: true,
        risk_level: "high"
      ),
      Definition.new(
        key: "operations.ai_enabled",
        category: "operation",
        value_type: "boolean",
        default: true,
        editable: true,
        risk_level: "high"
      ),
      Definition.new(
        key: "amount_engine.tax_excluded_price_conversion_enabled",
        category: "amount_engine",
        value_type: "boolean",
        default: true,
        editable: true,
        risk_level: "high"
      ),
      Definition.new(
        key: "amount_engine.max_candidate_snapshot_count",
        category: "amount_engine",
        value_type: "integer",
        default: 3,
        editable: true,
        risk_level: "low",
        min: 1,
        max: 20
      ),
      Definition.new(
        key: "ui.maintenance_notice_enabled",
        category: "ui_toggle",
        value_type: "boolean",
        default: false,
        editable: true,
        risk_level: "low"
      ),
      Definition.new(
        key: "ui.maintenance_notice_title",
        category: "ui_notice",
        value_type: "string",
        default: "",
        editable: true,
        risk_level: "low",
        max: 80
      ),
      Definition.new(
        key: "ui.maintenance_notice_body",
        category: "ui_notice",
        value_type: "string",
        default: "",
        editable: true,
        risk_level: "low",
        max: 1000
      ),
      Definition.new(
        key: "maintenance.mode",
        category: "maintenance",
        value_type: "enum",
        default: "off",
        editable: true,
        risk_level: "high",
        allowed_values: %w[off login_restricted]
      ),
      Definition.new(
        key: "maintenance.title",
        category: "maintenance",
        value_type: "string",
        default: "",
        editable: true,
        risk_level: "medium",
        max: 80
      ),
      Definition.new(
        key: "maintenance.body",
        category: "maintenance",
        value_type: "string",
        default: "",
        editable: true,
        risk_level: "medium",
        max: 1000
      ),
      Definition.new(
        key: "security.admin_passkey_reauth_window_minutes",
        category: "security",
        value_type: "integer",
        default: 5,
        editable: true,
        risk_level: "high",
        min: 1,
        max: 60
      ),
      Definition.new(
        key: "security_events.max_detections_per_request",
        category: "security_event",
        value_type: "integer",
        default: 5,
        editable: true,
        risk_level: "high",
        min: 1,
        max: 50
      ),
      Definition.new(
        key: "security_events.aggregation_window_minutes",
        category: "security_event",
        value_type: "integer",
        default: 60,
        editable: true,
        risk_level: "medium",
        min: 5,
        max: 1440
      ),
      Definition.new(
        key: "security_events.admin_burst_window_minutes",
        category: "security_event",
        value_type: "integer",
        default: 60,
        editable: true,
        risk_level: "high",
        min: 5,
        max: 1440
      ),
      Definition.new(
        key: "security_events.admin_burst_threshold",
        category: "security_event",
        value_type: "integer",
        default: 5,
        editable: true,
        risk_level: "high",
        min: 2,
        max: 100
      ),
      Definition.new(
        key: "external_services.failure_window_minutes",
        category: "external_service_status",
        value_type: "integer",
        default: 5,
        editable: true,
        risk_level: "high",
        min: 1,
        max: 60
      ),
      Definition.new(
        key: "external_services.degraded_failure_threshold",
        category: "external_service_status",
        value_type: "integer",
        default: 2,
        editable: true,
        risk_level: "high",
        min: 1,
        max: 20
      ),
      Definition.new(
        key: "external_services.down_failure_threshold",
        category: "external_service_status",
        value_type: "integer",
        default: 3,
        editable: true,
        risk_level: "high",
        min: 2,
        max: 50
      ),
      Definition.new(
        key: "external_services.recovery_success_threshold",
        category: "external_service_status",
        value_type: "integer",
        default: 2,
        editable: true,
        risk_level: "high",
        min: 1,
        max: 20
      ),
      Definition.new(
        key: "storage.keep_receipt_images_default",
        category: "storage_policy",
        value_type: "boolean",
        default: true,
        editable: true,
        risk_level: "medium"
      ),
      Definition.new(
        key: "storage.usage_warning_percentage",
        category: "storage_warning",
        value_type: "integer",
        default: 80,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 99
      ),
      Definition.new(
        key: "storage.usage_error_percentage",
        category: "storage_warning",
        value_type: "integer",
        default: 95,
        editable: true,
        risk_level: "medium",
        min: 2,
        max: 100
      ),
      Definition.new(
        key: "storage.warning_remaining_bytes",
        category: "storage_warning",
        value_type: "integer",
        default: 200.megabytes,
        editable: true,
        risk_level: "medium",
        min: 1.megabyte,
        max: 20.gigabytes
      ),
      Definition.new(
        key: "storage.error_remaining_bytes",
        category: "storage_warning",
        value_type: "integer",
        default: 50.megabytes,
        editable: true,
        risk_level: "medium",
        min: 1.megabyte,
        max: 10.gigabytes
      ),
      Definition.new(
        key: "storage.remaining_warning_limit_bytes",
        category: "storage_warning",
        value_type: "integer",
        default: 1.gigabyte,
        editable: true,
        risk_level: "medium",
        min: 10.megabytes,
        max: 100.gigabytes
      ),
      Definition.new(
        key: "storage.global_hard_stop_bytes",
        category: "storage_warning",
        value_type: "integer",
        default: 20.gigabytes,
        editable: true,
        risk_level: "high",
        min: 1.gigabyte,
        max: 20.terabytes
      ),
      Definition.new(
        key: "storage.global_usage_warning_percentage",
        category: "storage_warning",
        value_type: "integer",
        default: 75,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 99
      ),
      Definition.new(
        key: "storage.global_usage_critical_percentage",
        category: "storage_warning",
        value_type: "integer",
        default: 90,
        editable: true,
        risk_level: "high",
        min: 2,
        max: 100
      ),
      Definition.new(
        key: "limits.receipt_upload_soft_limit",
        category: "soft_limit",
        value_type: "integer",
        default: 100,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 1000
      ),
      Definition.new(
        key: "limits.receipt_uploads_per_day",
        category: "usage_limit",
        value_type: "integer",
        default: 50,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 10_000
      ),
      Definition.new(
        key: "limits.manual_receipts_per_day",
        category: "usage_limit",
        value_type: "integer",
        default: 50,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 1000
      ),
      Definition.new(
        key: "limits.receipt_items_per_receipt",
        category: "usage_limit",
        value_type: "integer",
        default: 100,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 10_000
      ),
      Definition.new(
        key: "limits.receipt_adjustments_per_receipt",
        category: "usage_limit",
        value_type: "integer",
        default: 50,
        editable: true,
        risk_level: "medium",
        min: 0,
        max: 200
      ),
      Definition.new(
        key: "limits.receipt_payments_per_receipt",
        category: "usage_limit",
        value_type: "integer",
        default: 20,
        editable: true,
        risk_level: "medium",
        min: 0,
        max: 100
      ),
      Definition.new(
        key: "limits.receipt_tax_details_per_receipt",
        category: "usage_limit",
        value_type: "integer",
        default: 20,
        editable: true,
        risk_level: "medium",
        min: 0,
        max: 100
      ),
      Definition.new(
        key: "limits.receipt_total_amount_max",
        category: "amount_limit",
        value_type: "integer",
        default: SystemSettings::AMOUNT_LIMIT_DEFAULT,
        editable: true,
        risk_level: "high",
        min: 1,
        max: SystemSettings::AMOUNT_LIMIT_CONFIGURABLE_MAX
      ),
      Definition.new(
        key: "limits.receipt_item_price_max",
        category: "amount_limit",
        value_type: "integer",
        default: SystemSettings::AMOUNT_LIMIT_DEFAULT,
        editable: true,
        risk_level: "high",
        min: 1,
        max: SystemSettings::AMOUNT_LIMIT_CONFIGURABLE_MAX
      ),
      Definition.new(
        key: "limits.receipt_item_line_total_max",
        category: "amount_limit",
        value_type: "integer",
        default: SystemSettings::AMOUNT_LIMIT_DEFAULT,
        editable: true,
        risk_level: "high",
        min: 1,
        max: SystemSettings::AMOUNT_LIMIT_CONFIGURABLE_MAX
      ),
      Definition.new(
        key: "limits.receipt_tax_amount_max",
        category: "amount_limit",
        value_type: "integer",
        default: SystemSettings::AMOUNT_LIMIT_DEFAULT,
        editable: true,
        risk_level: "high",
        min: 1,
        max: SystemSettings::AMOUNT_LIMIT_CONFIGURABLE_MAX
      ),
      Definition.new(
        key: "limits.receipt_adjustment_amount_max",
        category: "amount_limit",
        value_type: "integer",
        default: SystemSettings::AMOUNT_LIMIT_DEFAULT,
        editable: true,
        risk_level: "high",
        min: 1,
        max: SystemSettings::AMOUNT_LIMIT_CONFIGURABLE_MAX
      ),
      Definition.new(
        key: "limits.receipt_payment_amount_max",
        category: "amount_limit",
        value_type: "integer",
        default: SystemSettings::AMOUNT_LIMIT_DEFAULT,
        editable: true,
        risk_level: "high",
        min: 1,
        max: SystemSettings::AMOUNT_LIMIT_CONFIGURABLE_MAX
      ),
      Definition.new(
        key: "limits.notifications_per_user",
        category: "usage_limit",
        value_type: "integer",
        default: 100,
        editable: true,
        risk_level: "medium",
        min: 20,
        max: 500
      ),
      Definition.new(
        key: "limits.batch_upload_max_files",
        category: "usage_limit",
        value_type: "integer",
        default: 5,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 20
      ),
      Definition.new(
        key: "limits.public_announcements_per_page",
        category: "usage_limit",
        value_type: "integer",
        default: 10,
        editable: true,
        risk_level: "low",
        min: 1,
        max: 50
      ),
      Definition.new(
        key: "limits.contact_request_url_count",
        category: "usage_limit",
        value_type: "integer",
        default: 5,
        editable: true,
        risk_level: "medium",
        min: 0,
        max: 20
      ),
      Definition.new(
        key: "limits.receipt_image_max_file_size_bytes",
        category: "upload_limit",
        value_type: "integer",
        default: 20.megabytes,
        editable: true,
        risk_level: "high",
        min: 1.megabyte,
        max: 50.megabytes
      ),
      Definition.new(
        key: "limits.receipt_image_min_dimension_px",
        category: "upload_limit",
        value_type: "integer",
        default: 100,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 5000
      ),
      Definition.new(
        key: "limits.receipt_image_max_dimension_px",
        category: "upload_limit",
        value_type: "integer",
        default: 10_000,
        editable: true,
        risk_level: "high",
        min: 1000,
        max: 20_000
      ),
      Definition.new(
        key: "limits.announcement_image_max_file_size_bytes",
        category: "upload_limit",
        value_type: "integer",
        default: 2.megabytes,
        editable: true,
        risk_level: "high",
        min: 100.kilobytes,
        max: 10.megabytes
      ),
      Definition.new(
        key: "limits.announcement_image_min_dimension_px",
        category: "upload_limit",
        value_type: "integer",
        default: 100,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 4096
      ),
      Definition.new(
        key: "limits.announcement_image_max_dimension_px",
        category: "upload_limit",
        value_type: "integer",
        default: 4096,
        editable: true,
        risk_level: "high",
        min: 1000,
        max: 10_000
      ),
      Definition.new(
        key: "limits.avatar_image_max_file_size_bytes",
        category: "upload_limit",
        value_type: "integer",
        default: 5.megabytes,
        editable: true,
        risk_level: "high",
        min: 100.kilobytes,
        max: 20.megabytes
      ),
      Definition.new(
        key: "analysis_artifact.ocr_raw_response_max_bytes",
        category: "analysis_artifact",
        value_type: "integer",
        default: 5.megabytes,
        editable: true,
        risk_level: "high",
        min: 64.kilobytes,
        max: 20.megabytes
      ),
      Definition.new(
        key: "retention.notifications_read_days",
        category: "retention",
        value_type: "integer",
        default: 30,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 365
      ),
      Definition.new(
        key: "retention.guest_users_days",
        category: "retention",
        value_type: "integer",
        default: 7,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 90
      ),
      Definition.new(
        key: "retention.user_sessions_days",
        category: "retention",
        value_type: "integer",
        default: 90,
        editable: true,
        risk_level: "medium",
        min: 30,
        max: 365
      ),
      Definition.new(
        key: "retention.contact_requests_days",
        category: "retention",
        value_type: "integer",
        default: 180,
        editable: true,
        risk_level: "medium",
        min: 30,
        max: 730
      ),
      Definition.new(
        key: "retention.analysis_runs_short_days",
        category: "retention",
        value_type: "integer",
        default: 14,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 365
      ),
      Definition.new(
        key: "retention.analysis_runs_default_days",
        category: "retention",
        value_type: "integer",
        default: 30,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 365
      ),
      Definition.new(
        key: "retention.analysis_runs_failed_days",
        category: "retention",
        value_type: "integer",
        default: 90,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 365
      ),
      Definition.new(
        key: "analysis_artifact.ocr_raw_response_retention_days",
        category: "analysis_artifact",
        value_type: "integer",
        default: 7,
        editable: true,
        risk_level: "high",
        min: 1,
        max: 90
      ),
      Definition.new(
        key: "retention.orphan_blobs_hours",
        category: "retention",
        value_type: "integer",
        default: 48,
        editable: true,
        risk_level: "high",
        min: 24,
        max: 720
      ),
      Definition.new(
        key: "retention.receipt_images_days",
        category: "retention",
        value_type: "integer",
        default: 1,
        editable: true,
        risk_level: "high",
        min: 1,
        max: 365
      ),
      Definition.new(
        key: "retention.security_events_critical_days",
        category: "retention",
        value_type: "integer",
        default: 180,
        editable: true,
        risk_level: "high",
        min: 30,
        max: 1095
      ),
      Definition.new(
        key: "retention.security_events_high_days",
        category: "retention",
        value_type: "integer",
        default: 180,
        editable: true,
        risk_level: "high",
        min: 30,
        max: 1095
      ),
      Definition.new(
        key: "retention.security_events_medium_days",
        category: "retention",
        value_type: "integer",
        default: 90,
        editable: true,
        risk_level: "high",
        min: 30,
        max: 730
      ),
      Definition.new(
        key: "retention.security_events_low_days",
        category: "retention",
        value_type: "integer",
        default: 30,
        editable: true,
        risk_level: "high",
        min: 7,
        max: 365
      ),
      Definition.new(
        key: "retention.audit_logs_high_risk_admin_days",
        category: "retention",
        value_type: "integer",
        default: 365,
        editable: true,
        risk_level: "high",
        min: 90,
        max: 3650
      ),
      Definition.new(
        key: "retention.audit_logs_cleanup_execute_days",
        category: "retention",
        value_type: "integer",
        default: 365,
        editable: true,
        risk_level: "high",
        min: 90,
        max: 3650
      ),
      Definition.new(
        key: "retention.audit_logs_cleanup_failed_days",
        category: "retention",
        value_type: "integer",
        default: 180,
        editable: true,
        risk_level: "high",
        min: 30,
        max: 1825
      ),
      Definition.new(
        key: "retention.audit_logs_passkey_reauth_days",
        category: "retention",
        value_type: "integer",
        default: 90,
        editable: true,
        risk_level: "high",
        min: 30,
        max: 730
      ),
      Definition.new(
        key: "retention.audit_logs_system_dry_run_days",
        category: "retention",
        value_type: "integer",
        default: 30,
        editable: true,
        risk_level: "high",
        min: 7,
        max: 365
      ),
      Definition.new(
        key: "retention.audit_logs_routine_system_days",
        category: "retention",
        value_type: "integer",
        default: 90,
        editable: true,
        risk_level: "high",
        min: 30,
        max: 730
      ),
      Definition.new(
        key: "limits.max_uploads_per_day",
        category: "usage_limit_safety",
        value_type: "integer",
        default: 1000,
        editable: true,
        risk_level: "high",
        min: 50,
        max: 10_000
      ),
      Definition.new(
        key: "limits.max_ocr_per_day",
        category: "usage_limit_safety",
        value_type: "integer",
        default: 1000,
        editable: true,
        risk_level: "high",
        min: 50,
        max: 10_000
      ),
      Definition.new(
        key: "limits.max_ai_per_day",
        category: "usage_limit_safety",
        value_type: "integer",
        default: 1000,
        editable: true,
        risk_level: "high",
        min: 50,
        max: 10_000
      ),
      Definition.new(
        key: "limits.max_storage_bytes",
        category: "usage_limit_safety",
        value_type: "integer",
        default: 100.gigabytes,
        editable: true,
        risk_level: "high",
        min: 1.gigabyte,
        max: 1.terabyte
      ),
      Definition.new(
        key: "limits.snapshot_ocr_items_max",
        category: "snapshot_limit",
        value_type: "integer",
        default: 1000,
        editable: true,
        risk_level: "high",
        min: 100,
        max: 10_000
      ),
      Definition.new(
        key: "limits.snapshot_ai_normalized_items_max",
        category: "snapshot_limit",
        value_type: "integer",
        default: 1000,
        editable: true,
        risk_level: "high",
        min: 100,
        max: 10_000
      ),
      Definition.new(
        key: "limits.snapshot_ocr_lines_max",
        category: "snapshot_limit",
        value_type: "integer",
        default: 150,
        editable: true,
        risk_level: "high",
        min: 10,
        max: 1000
      ),
      Definition.new(
        key: "limits.snapshot_ai_input_full_context_lines_max",
        category: "snapshot_limit",
        value_type: "integer",
        default: 150,
        editable: true,
        risk_level: "high",
        min: 10,
        max: 1000
      ),
      Definition.new(
        key: "limits.snapshot_ai_input_adjustment_context_lines_max",
        category: "snapshot_limit",
        value_type: "integer",
        default: 40,
        editable: true,
        risk_level: "medium",
        min: 10,
        max: 500
      ),
      Definition.new(
        key: "limits.snapshot_ai_input_filtered_content_max_bytes",
        category: "snapshot_limit",
        value_type: "integer",
        default: 8.kilobytes,
        editable: true,
        risk_level: "high",
        min: 1.kilobyte,
        max: 100.kilobytes
      ),
      Definition.new(
        key: "limits.snapshot_string_max_bytes",
        category: "snapshot_limit",
        value_type: "integer",
        default: 500,
        editable: true,
        risk_level: "high",
        min: 100,
        max: 5000
      ),
      Definition.new(
        key: "limits.snapshot_ai_input_items_max",
        category: "snapshot_limit",
        value_type: "integer",
        default: 50,
        editable: true,
        risk_level: "high",
        min: 10,
        max: 5000
      ),
      Definition.new(
        key: "limits.snapshot_store_candidates_max",
        category: "snapshot_limit",
        value_type: "integer",
        default: 10,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 100
      ),
      Definition.new(
        key: "limits.snapshot_purchase_candidates_max",
        category: "snapshot_limit",
        value_type: "integer",
        default: 5,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 50
      ),
      Definition.new(
        key: "limits.snapshot_payment_candidates_max",
        category: "snapshot_limit",
        value_type: "integer",
        default: 10,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 100
      ),
      Definition.new(
        key: "limits.snapshot_tax_details_max",
        category: "snapshot_limit",
        value_type: "integer",
        default: 10,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 100
      ),
      Definition.new(
        key: "limits.snapshot_review_reasons_max",
        category: "snapshot_limit",
        value_type: "integer",
        default: 20,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 100
      ),
      Definition.new(
        key: "limits.ai_prompt_filtered_content_lines_max",
        category: "ai_prompt_limit",
        value_type: "integer",
        default: 40,
        editable: true,
        risk_level: "high",
        min: 5,
        max: 500
      ),
      Definition.new(
        key: "limits.ai_prompt_full_context_lines_max",
        category: "ai_prompt_limit",
        value_type: "integer",
        default: 150,
        editable: true,
        risk_level: "high",
        min: 10,
        max: 1000
      ),
      Definition.new(
        key: "limits.ai_prompt_raw_text_length_max",
        category: "ai_prompt_limit",
        value_type: "integer",
        default: 4000,
        editable: true,
        risk_level: "high",
        min: 500,
        max: 50_000
      ),
      Definition.new(
        key: "limits.ai_prompt_purchase_candidates_max",
        category: "ai_prompt_limit",
        value_type: "integer",
        default: 5,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 50
      ),
      Definition.new(
        key: "limits.store_name_casing_context_lines_max",
        category: "analysis_quality",
        value_type: "integer",
        default: 12,
        editable: true,
        risk_level: "medium",
        min: 0,
        max: 50
      ),
      Definition.new(
        key: "limits.batch_files_per_day",
        category: "usage_limit",
        value_type: "integer",
        default: 50,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 10_000
      ),
      Definition.new(
        key: "limits.ocr_jobs_per_day",
        category: "usage_limit",
        value_type: "integer",
        default: 50,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 10_000
      ),
      Definition.new(
        key: "limits.ai_jobs_per_day",
        category: "usage_limit",
        value_type: "integer",
        default: 50,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 10_000
      ),
      Definition.new(
        key: "limits.retry_operations_per_day",
        category: "usage_limit",
        value_type: "integer",
        default: 20,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 200
      ),
      Definition.new(
        key: "limits.guest_receipt_uploads_per_day",
        category: "usage_limit",
        value_type: "integer",
        default: 5,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 100
      ),
      Definition.new(
        key: "limits.guest_manual_receipts_per_day",
        category: "usage_limit",
        value_type: "integer",
        default: 5,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 100
      ),
      Definition.new(
        key: "limits.guest_batch_files_per_day",
        category: "usage_limit",
        value_type: "integer",
        default: 5,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 100
      ),
      Definition.new(
        key: "limits.guest_ocr_jobs_per_day",
        category: "usage_limit",
        value_type: "integer",
        default: 5,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 100
      ),
      Definition.new(
        key: "limits.guest_ai_jobs_per_day",
        category: "usage_limit",
        value_type: "integer",
        default: 5,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 100
      ),
      Definition.new(
        key: "limits.guest_storage_bytes",
        category: "usage_limit",
        value_type: "integer",
        default: 50.megabytes,
        editable: true,
        risk_level: "medium",
        min: 1.megabyte,
        max: 1.gigabyte
      ),
      Definition.new(
        key: "limits.api_requests_per_minute",
        category: "usage_limit",
        value_type: "integer",
        default: 60,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 1000
      ),
      Definition.new(
        key: "limits.api_requests_per_day",
        category: "usage_limit",
        value_type: "integer",
        default: 1000,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 100_000
      )
    ].index_by(&:key).freeze

    class << self
      def all
        ALL
      end
    end
  end
end
