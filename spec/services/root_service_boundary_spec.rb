require "rails_helper"
require_relative "../support/application_structure_boundary_scanner"

RSpec.describe "root service and lifecycle status boundary" do
  ROOT_CLASSIFICATIONS = {
    "admin.rb" => { constant: "Admin", role: :public_facade, owner: "admin read API and reauthentication policy facade", remove_in_loop: nil },
    "analysis.rb" => { constant: "Analysis", role: :public_facade, owner: "receipt analysis specialist facade", remove_in_loop: nil },
    "audit_logs.rb" => { constant: "AuditLogs", role: :public_facade, owner: "audit platform facade", remove_in_loop: nil },
    "bot_protection.rb" => { constant: "BotProtection", role: :public_facade, owner: "bot protection facade", remove_in_loop: nil },
    "contact_requests.rb" => { constant: "ContactRequests", role: :public_facade, owner: "contact request facade", remove_in_loop: nil },
    "external_services.rb" => { constant: "ExternalServices", role: :public_facade, owner: "external service platform facade", remove_in_loop: nil },
    "maintenance.rb" => { constant: "Maintenance", role: :public_facade, owner: "maintenance policy facade", remove_in_loop: nil },
    "passkeys.rb" => { constant: "Passkeys", role: :public_facade, owner: "WebAuthn facade", remove_in_loop: nil },
    "production_data_plane_validator.rb" => { constant: "ProductionDataPlaneValidator", role: :platform_contract, owner: "production boot validation", remove_in_loop: nil },
    "production_env_validator.rb" => { constant: "ProductionEnvValidator", role: :platform_contract, owner: "production environment validation", remove_in_loop: nil },
    "production_legal_documents_validator.rb" => { constant: "ProductionLegalDocumentsValidator", role: :platform_contract, owner: "production legal document validation", remove_in_loop: nil },
    "production_runtime_config.rb" => { constant: "ProductionRuntimeConfig", role: :platform_contract, owner: "production runtime configuration", remove_in_loop: nil },
    "receipt_ai_enrichment_service.rb" => { constant: "ReceiptAiEnrichmentService", role: :public_facade, owner: "AI specialist facade", remove_in_loop: nil },
    "receipt_amount_limits.rb" => { constant: "ReceiptAmountLimits", role: :legacy_policy, owner: "move behind ReceiptAmountService", remove_in_loop: 19 },
    "receipt_amount_service.rb" => { constant: "ReceiptAmountService", role: :public_facade, owner: "Amount Engine facade", remove_in_loop: nil },
    "receipt_analysis_pipeline.rb" => { constant: "ReceiptAnalysisPipeline", role: :legacy_workflow, owner: "migrate to Receipts::Processing", remove_in_loop: 22 },
    "receipt_analysis_profiles.rb" => { constant: "ReceiptAnalysisProfiles", role: :public_facade, owner: "country analysis profile facade", remove_in_loop: nil },
    "receipt_analysis_runs.rb" => { constant: "ReceiptAnalysisRuns", role: :legacy_workflow, owner: "migrate to Receipts::Processing run lifecycle", remove_in_loop: 22 },
    "receipt_ocr_service.rb" => { constant: "ReceiptOcrService", role: :public_facade, owner: "OCR specialist facade", remove_in_loop: nil },
    "review_reasons.rb" => { constant: "ReviewReasons", role: :domain_policy, owner: "review reason policy", remove_in_loop: nil },
    "security.rb" => { constant: "Security", role: :public_facade, owner: "security platform facade", remove_in_loop: nil },
    "security_events.rb" => { constant: "SecurityEvents", role: :public_facade, owner: "security event facade", remove_in_loop: nil },
    "sensitive_metadata_keys.rb" => { constant: "SensitiveMetadataKeys", role: :domain_policy, owner: "sensitive metadata key catalog", remove_in_loop: nil },
    "storage.rb" => { constant: "Storage", role: :public_facade, owner: "storage platform facade", remove_in_loop: nil },
    "system_operations.rb" => { constant: "SystemOperations", role: :public_facade, owner: "high-risk operation facade", remove_in_loop: nil },
    "system_settings.rb" => { constant: "SystemSettings", role: :public_facade, owner: "system setting facade", remove_in_loop: nil },
    "two_factor.rb" => { constant: "TwoFactor", role: :public_facade, owner: "two-factor authentication facade", remove_in_loop: nil },
    "usage.rb" => { constant: "Usage", role: :public_facade, owner: "usage and limit facade", remove_in_loop: nil },
    "user_limits.rb" => { constant: "UserLimits", role: :domain_policy, owner: "user limit policy", remove_in_loop: nil },
    "user_sessions.rb" => { constant: "UserSessions", role: :public_facade, owner: "user session lifecycle facade", remove_in_loop: nil },
    "users.rb" => { constant: "Users", role: :public_facade, owner: "user account workflow facade", remove_in_loop: nil }
  }.freeze

  EXTERNAL_METHODS = {
    "admin.rb" => %i[announcement_filter_options announcements audit_log_filter_options audit_logs contact_request contact_request_filter_options contact_requests dashboard database_status_snapshot ip_actions ip_block ip_block_filter_options ip_blocks legal_acceptance_status passkey_reauth_fresh? passkey_reauth_window_duration passkey_reauthenticated_at receipt receipt_analysis_cleanup_preview receipt_analysis_run_filter_options receipt_analysis_runs receipts security_event security_event_filter_options security_events system_operations_dashboard system_setting system_settings user users],
    "analysis.rb" => %i[build_receipt_params detect_category enforce_ownership_consistency evaluate_receipt_signal money_token_matches normalize_compact_store_name_candidate normalize_receipt_items normalize_store_name_candidate ownership_review_reason_resolved? processing_error_category processing_error_mapping store_name_brand_candidate_from_legal_entity store_name_candidate_valid? store_name_customer_facing_heading_candidates store_name_descriptive_heading_line? store_name_isolated_logo_fragment? store_name_latin_logo_prefix_duplicate? store_name_legal_entity_name? store_name_message_line? store_name_operator_candidates store_name_operator_context_line? store_name_operator_legal_entity_candidate? tax_detail_line_evidence],
    "audit_logs.rb" => %i[cleanup_retention record_admin_action! record_system_action! sanitize],
    "bot_protection.rb" => %i[failure_result success_result turnstile_enabled? turnstile_site_key verify_turnstile],
    "contact_requests.rb" => %i[anonymizable_scope anonymize anonymized? category_options cleanup_retention contact_request_retention_days create email_digest retention_cutoff],
    "external_services.rb" => %i[check_available? debug_switch_available? deserialize_runtime_config_snapshot down? error_detail mark_failure! mark_monitor_failure! mark_success! runtime_config_snapshot services_due_for_check snapshot snapshots state status_snapshot switch_debug_state unavailable_detail],
    "maintenance.rb" => %i[admin_bypass_user? body login_allowed_for? login_restricted? title],
    "passkeys.rb" => %i[discoverable_authentication_options reauthentication_options registration_limit registration_limit_reached? registration_options remaining_slots_for step_up_options verify_discoverable_authentication verify_reauthentication verify_registration verify_step_up],
    "production_data_plane_validator.rb" => %i[validate!],
    "production_env_validator.rb" => %i[boot_validate! validate!],
    "production_legal_documents_validator.rb" => %i[],
    "production_runtime_config.rb" => %i[new],
    "receipt_ai_enrichment_service.rb" => %i[available? call error_result provider_metrics],
    "receipt_amount_limits.rb" => %i[receipt_adjustment_amount_max receipt_item_line_total_max receipt_item_price_max receipt_payment_amount_max receipt_tax_amount_max receipt_total_amount_max violations_for],
    "receipt_amount_service.rb" => %i[adjustment_classification adjustment_effect apply_rounding calculation_profile_snapshot call parse_amount parse_amount_or_nil parse_quantity payment_adjustment_kinds payment_adjustment_summary warning_mismatch_codes],
    "receipt_analysis_pipeline.rb" => %i[finalize_decision_from_snapshot run_ai run_finalize run_ocr],
    "receipt_analysis_profiles.rb" => %i[default fetch],
    "receipt_analysis_runs.rb" => %i[cancel claim_stage cleanup_expired cleanup_stale copy_retry_snapshots enqueue external_service_runtime_config fail finish_stage record_ai_input record_ai_normalized_result record_ai_result record_build_params_snapshot record_final_result record_finalize_decision record_ocr_response_artifact record_ocr_result record_ocr_snapshot start start_stage succeed supersede],
    "receipt_ocr_service.rb" => %i[available? call error_result],
    "review_reasons.rb" => %i[blocking_reasons_for_user group_by_source normalize normalize_ai_output_reasons review_reasons_for_user user_facing_reason? warning_reasons_for_user],
    "security.rb" => %i[ip_access_snapshot manual_ip_block manual_ip_unblock rack_attack_ban_reset record_ip_access_operation record_ip_rate_limit_action request_ip_snapshot],
    "security_events.rb" => %i[cleanup_retention detect record! record_admin_audit_burst! record_csrf_failure! record_external_service_failure! record_invalid_upload! record_rate_limit! record_request_detections! record_suspicious_error! sanitize_exception_message sanitize_metadata sanitize_text],
    "sensitive_metadata_keys.rb" => %i[],
    "storage.rb" => %i[extract_image_dimensions global_quota global_quota_can_add? orphan_blob_scan purge_attachment purge_receipt_images system_usage_snapshot usage_calculator],
    "system_operations.rb" => %i[execute_ip_access_operation execute_receipt_analysis_cleanup execute_receipt_analysis_retry execute_receipt_moderation_operation execute_user_operation receipt_analysis_retry_confirmation_text receipt_analysis_retry_eligibility receipt_analysis_retry_types reset_setting update_setting update_user_limit user_limit_update_confirmation_text],
    "system_settings.rb" => %i[audit_value cast_update_value definition_for definitions dependency_lock_groups_for enabled? fetch limit_for limits_for stored_value valid_key? validate_stored_value! value_for values_for],
    "two_factor.rb" => %i[confirm_totp_setup disable_totp_for prepare_totp_setup recovery_codes_status regenerate_recovery_codes_for totp_provisioning_uri totp_qr_svg verify_recovery_code verify_totp],
    "usage.rb" => %i[consume_ai_job! consume_batch_upload! consume_manual_receipt! consume_ocr_job! consume_receipt_upload! consume_retry_operation! counter_summary_for ensure_ai_job_within_limit! ensure_ocr_job_within_limit!],
    "user_limits.rb" => %i[cast_value definitions effective_limit entry_for stored_value summary_for valid_key?],
    "user_sessions.rb" => %i[cleanup_retention mark_revoked_for_user record_sign_in record_sign_out retention_cutoff summary_for touch_current],
    "users.rb" => %i[account_deletion_email_digest delete_account]
  }.freeze

  DECLARED_SINGLETON_METHODS = {
    "admin.rb" => EXTERNAL_METHODS.fetch("admin.rb"),
    "analysis.rb" => %i[build_receipt_params detect_category enforce_ownership_consistency evaluate_receipt_signal money_token_matches normalize_compact_store_name_candidate normalize_receipt_items normalize_store_name_candidate ownership_review_reason_resolved? processing_error_category processing_error_mapping receipt_item_ai_allowed_keys resolve_receipt_fact_ownership source_evidence_index store_name_brand_candidate_from_legal_entity store_name_candidate_valid? store_name_customer_facing_heading_candidates store_name_descriptive_heading_line? store_name_isolated_logo_fragment? store_name_latin_logo_prefix_duplicate? store_name_legal_entity_name? store_name_message_line? store_name_operator_candidates store_name_operator_context_line? store_name_operator_legal_entity_candidate? tax_detail_line_evidence],
    "audit_logs.rb" => EXTERNAL_METHODS.fetch("audit_logs.rb"),
    "bot_protection.rb" => EXTERNAL_METHODS.fetch("bot_protection.rb"),
    "contact_requests.rb" => %i[anonymizable_scope anonymize anonymized? category_options cleanup_retention contact_request_retention_days create email_digest max_url_count retention_cutoff retention_scope],
    "external_services.rb" => %i[check_available? debug_switch_available? degraded? deserialize_runtime_config_snapshot down? due_for_check? error_detail external_error? mark_failure! mark_monitor_failure! mark_success! monitoring? ok? reset! runtime_config_snapshot services services_due_for_check snapshot snapshots state status_snapshot switch_debug_state unavailable_detail],
    "maintenance.rb" => %i[active? admin_bypass_user? body login_allowed_for? login_restricted? mode off? title],
    "passkeys.rb" => %i[authentication_options count_for discoverable_authentication_options reauthentication_options registration_limit registration_limit_reached? registration_options remaining_slots_for step_up_options verify_authentication verify_discoverable_authentication verify_reauthentication verify_registration verify_step_up],
    "production_data_plane_validator.rb" => %i[call validate!],
    "production_env_validator.rb" => %i[boot_validate! call validate!],
    "production_legal_documents_validator.rb" => %i[call validate!],
    "production_runtime_config.rb" => %i[],
    "receipt_ai_enrichment_service.rb" => %i[available? call error_result provider_metrics],
    "receipt_amount_limits.rb" => %i[limit_for receipt_adjustment_amount_max receipt_item_line_total_max receipt_item_price_max receipt_payment_amount_max receipt_tax_amount_max receipt_total_amount_max violations_for],
    "receipt_amount_service.rb" => %i[adjustment_classification adjustment_effect apply_rounding calculation_profile_snapshot call mismatch_code parse_amount parse_amount_or_nil parse_quantity payment_adjustment_kinds payment_adjustment_summary warning_mismatch_codes],
    "receipt_analysis_pipeline.rb" => %i[finalize finalize_decision_from_snapshot run_ai run_finalize run_ocr],
    "receipt_analysis_profiles.rb" => %i[default fetch for_country],
    "receipt_analysis_runs.rb" => %i[cancel claim_stage cleanup_expired cleanup_stale copy_retry_snapshots enqueue external_service_runtime_config fail finish_stage record_ai_input record_ai_normalized_result record_ai_result record_build_params_snapshot record_final_result record_finalize_decision record_ocr_response_artifact record_ocr_result record_ocr_snapshot start start_stage succeed supersede],
    "receipt_ocr_service.rb" => %i[available? call error_result],
    "review_reasons.rb" => %i[blocking_reason? blocking_reasons_for_user group_by_source internal_processing_reasons known_reason? normalize normalize_ai_output_reasons normalize_allowed_reasons review_reasons_for_user source_for user_facing_reason? warning_reason? warning_reasons_for_user],
    "security.rb" => %i[ip_access_snapshot manual_ip_block manual_ip_unblock rack_attack_ban_reset record_ip_access_operation record_ip_action record_ip_rate_limit_action request_ip_snapshot],
    "security_events.rb" => EXTERNAL_METHODS.fetch("security_events.rb"),
    "sensitive_metadata_keys.rb" => %i[],
    "storage.rb" => EXTERNAL_METHODS.fetch("storage.rb"),
    "system_operations.rb" => %i[execute_ip_access_operation execute_receipt_analysis_cleanup execute_receipt_analysis_retry execute_receipt_moderation_operation execute_user_operation receipt_analysis_retry_confirmation_text receipt_analysis_retry_eligibility receipt_analysis_retry_types reset_setting update_setting update_user_limit user_limit_update_confirmation_text],
    "system_settings.rb" => %i[audit_value cast_update_value definition_for definitions dependency_lock_groups_for editable? enabled? fetch limit_for limits_for rollout_enabled? source_for stored_value stored_value_for_update valid_key? validate_stored_value! value_for values_for],
    "two_factor.rb" => %i[confirm_totp_setup disable_totp_for generate_recovery_codes_for generate_totp_secret prepare_totp_setup recovery_code_digest recovery_codes_status regenerate_recovery_codes_for totp_provisioning_uri totp_qr_svg verify_recovery_code verify_totp verify_totp_setup],
    "usage.rb" => %i[consume_ai_job! consume_batch_upload! consume_manual_receipt! consume_ocr_job! consume_receipt_upload! consume_retry_operation! counter_summary_for effective_limit ensure_ai_job_within_limit! ensure_ocr_job_within_limit! limit_summary_for],
    "user_limits.rb" => %i[cast_value definition_for definitions effective_limit entry_for override_for stored_value summary_for valid_key?],
    "user_sessions.rb" => %i[active_for cleanup_retention mark_revoked_for_user record_sign_in record_sign_out retention_cutoff retention_days summary_for touch_current],
    "users.rb" => %i[account_deletion_email_digest delete_account]
  }.freeze

  DECLARED_INSTANCE_METHODS = {
    "production_data_plane_validator.rb" => %i[call validate!],
    "production_env_validator.rb" => %i[call validate!],
    "production_legal_documents_validator.rb" => %i[call validate!],
    "production_runtime_config.rb" => %i[additional_hosts app_host app_protocol assume_ssl? force_ssl? host_authorization_hosts mailer_default_url_options mailer_host mailer_protocol missing_smtp_env routes_default_url_options smtp_env_present? smtp_settings ssl_options],
    "receipt_ai_enrichment_service.rb" => %i[call],
    "receipt_amount_service.rb" => %i[call],
    "receipt_analysis_pipeline.rb" => %i[run_ai run_finalize run_ocr],
    "receipt_ocr_service.rb" => %i[call]
  }.freeze

  CONSTRUCTIBLE_ROOTS = %w[
    production_data_plane_validator.rb
    production_env_validator.rb
    production_legal_documents_validator.rb
    production_runtime_config.rb
    receipt_ai_enrichment_service.rb
    receipt_amount_service.rb
    receipt_analysis_pipeline.rb
    receipt_ocr_service.rb
  ].freeze

  ROOT_SERVICE_REGISTRY = ROOT_CLASSIFICATIONS.to_h do |file, classification|
    [
      file,
      classification.merge(
        external_methods: EXTERNAL_METHODS.fetch(file),
        declared_singleton_methods: DECLARED_SINGLETON_METHODS.fetch(file),
        declared_instance_methods: DECLARED_INSTANCE_METHODS.fetch(file, []),
        constructible: CONSTRUCTIBLE_ROOTS.include?(file)
      ).freeze
    ]
  end.freeze

  EXPECTED_STATUS_WRITE_FINGERPRINTS = {
    [ "app/controllers/receipts_controller.rb", :receipt, "@receipt", :status=, [ :status ] ] => 2,
    [ "app/services/system_operations/receipt_analysis_retry_executor.rb", :receipt, "receipt", :update!, [ :status ] ] => 1,
    [ "app/services/receipt_analysis_pipeline.rb", :receipt, "receipt", :update!, [ :status ] ] => 1,
    [ "app/services/receipt_analysis_runs.rb", :receipt, "receipt", :update!, [ :status ] ] => 1,
    [ "app/services/receipt_analysis_runs/starter.rb", :analysis_run, "receipt.receipt_analysis_runs", :create!, %i[status stage] ] => 1,
    [ "app/services/receipt_analysis_runs/starter.rb", :receipt, "receipt", :update!, [ :status ] ] => 1,
    [ "app/services/receipt_analysis_runs/tracker.rb", :analysis_run, "locked_run", :update!, %i[status stage] ] => 8,
    [ "app/services/receipt_analysis_runs/tracker.rb", :analysis_run, "run", :update!, %i[status stage] ] => 2,
    [ "app/services/receipt_analysis_runs/tracker.rb", :receipt, "receipt", :update!, [ :status ] ] => 2,
    [ "app/services/receipts/uploads/batch.rb", :receipt, "user.receipts", :new, [ :status ] ] => 1
  }.freeze

  INDIRECT_STATUS_OWNERS = {
    "app/controllers/receipts_controller.rb" => "legacy upload/manual/edit lifecycle owner; migrate in Loops 8/12/13/21",
    "app/services/receipt_analysis_pipeline/finalize_step.rb" => "final receipt status decision and persistence owner; migrate in Loops 14/18",
    "app/services/receipts/editing/review_state.rb" => "Receipts::Editing review status decision"
  }.freeze

  before(:context) do
    @scanner = ApplicationStructureBoundary::Scanner.new(
      root: Rails.root,
      registry: ROOT_SERVICE_REGISTRY,
      constant_path_resolver: ->(path) { Rails.autoloaders.main.cpath_expected_at(path) }
    )
  end

  let(:scanner) { @scanner }

  it "app/services rootの全ファイルを役割とowner付きで登録する" do
    expect(scanner.registry_issues).to be_empty, scanner.registry_issues.join("\n")
  end

  it "宣言済みpublic APIを増減させない" do
    expect(scanner.declared_api_issues).to be_empty, scanner.declared_api_issues.join("\n")
  end

  it "production callerが利用するroot public APIを増減させない" do
    expect(scanner.external_api_issues).to be_empty, scanner.external_api_issues.join("\n")
  end

  it "root APIとstatus writerのproduction sourceをPrismで解析できる" do
    formatted = scanner.analysis_issues.map { |issue| "#{issue.source_path}:#{issue.line}: #{issue.message}" }
    expect(formatted).to be_empty, formatted.join("\n")
  end

  it "ReceiptとReceiptAnalysisRunの直接status writer fingerprintを増減させない" do
    actual = scanner.status_writes.map do |write|
      [ write.source_path, write.record_type, write.receiver_source, write.method_name, write.attributes ]
    end.tally

    expect(actual).to eq(EXPECTED_STATUS_WRITE_FINGERPRINTS)
  end

  it "jobsとmodelsからlifecycle statusを直接変更しない" do
    forbidden = scanner.status_writes.select do |write|
      write.source_path.start_with?("app/jobs/", "app/models/")
    end

    expect(forbidden).to be_empty
  end

  it "間接的なstatus decision ownerを理由と削除予定付きで固定する" do
    missing = INDIRECT_STATUS_OWNERS.keys.reject { |path| Rails.root.join(path).file? }

    expect(missing).to be_empty
    expect(INDIRECT_STATUS_OWNERS.values).to all(be_present)
  end
end
