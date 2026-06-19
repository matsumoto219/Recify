# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_18_233112) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "announcement_links", force: :cascade do |t|
    t.bigint "announcement_id", null: false
    t.datetime "created_at", null: false
    t.boolean "external", default: false, null: false
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["announcement_id", "position"], name: "index_announcement_links_on_announcement_id_and_position"
    t.index ["announcement_id"], name: "index_announcement_links_on_announcement_id"
  end

  create_table "announcements", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.datetime "ends_at"
    t.string "image_alt_text"
    t.string "kind", default: "general", null: false
    t.boolean "pinned", default: false, null: false
    t.integer "priority", default: 0, null: false
    t.string "public_id", null: false
    t.datetime "published_at"
    t.datetime "starts_at"
    t.string "status", default: "draft", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "updated_by_id"
    t.index ["created_by_id"], name: "index_announcements_on_created_by_id"
    t.index ["ends_at"], name: "index_announcements_on_ends_at"
    t.index ["kind"], name: "index_announcements_on_kind"
    t.index ["public_id"], name: "index_announcements_on_public_id", unique: true
    t.index ["published_at"], name: "index_announcements_on_published_at"
    t.index ["starts_at"], name: "index_announcements_on_starts_at"
    t.index ["status", "pinned", "priority", "published_at"], name: "index_announcements_public_order"
    t.index ["status"], name: "index_announcements_on_status"
    t.index ["updated_by_id"], name: "index_announcements_on_updated_by_id"
  end

  create_table "audit_logs", force: :cascade do |t|
    t.string "action", null: false
    t.string "actor_kind", null: false
    t.bigint "actor_user_id"
    t.jsonb "after_state", default: {}, null: false
    t.jsonb "before_state", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "error_code"
    t.inet "ip_address"
    t.jsonb "metadata", default: {}, null: false
    t.string "outcome", null: false
    t.text "reason"
    t.string "request_id"
    t.bigint "target_id"
    t.string "target_type"
    t.string "target_uid"
    t.datetime "updated_at", null: false
    t.text "user_agent"
    t.index ["action", "created_at"], name: "index_audit_logs_on_action_and_created_at"
    t.index ["actor_user_id", "created_at"], name: "index_audit_logs_on_actor_user_id_and_created_at"
    t.index ["actor_user_id"], name: "index_audit_logs_on_actor_user_id"
    t.index ["created_at"], name: "index_audit_logs_on_created_at"
    t.index ["request_id"], name: "index_audit_logs_on_request_id"
    t.index ["target_type", "target_id", "created_at"], name: "index_audit_logs_on_target_type_and_target_id_and_created_at"
    t.index ["target_uid"], name: "index_audit_logs_on_target_uid"
  end

  create_table "contact_requests", force: :cascade do |t|
    t.text "body", null: false
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "email_digest", null: false
    t.datetime "handled_at"
    t.bigint "handled_by_user_id"
    t.inet "ip_address"
    t.string "request_id"
    t.string "request_uid", null: false
    t.string "sender_name", limit: 50
    t.string "source", null: false
    t.string "status", default: "open", null: false
    t.string "subject", null: false
    t.datetime "updated_at", null: false
    t.text "user_agent"
    t.bigint "user_id"
    t.index ["category"], name: "index_contact_requests_on_category"
    t.index ["created_at"], name: "index_contact_requests_on_created_at"
    t.index ["email_digest"], name: "index_contact_requests_on_email_digest"
    t.index ["handled_by_user_id"], name: "index_contact_requests_on_handled_by_user_id"
    t.index ["request_uid"], name: "index_contact_requests_on_request_uid", unique: true
    t.index ["status"], name: "index_contact_requests_on_status"
    t.index ["user_id"], name: "index_contact_requests_on_user_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.string "action_path"
    t.text "body"
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "notifiable_id"
    t.string "notifiable_type"
    t.datetime "read_at"
    t.string "title", null: false
    t.string "uid", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["notifiable_type", "notifiable_id"], name: "index_notifications_on_notifiable"
    t.index ["uid"], name: "index_notifications_on_uid", unique: true
    t.index ["user_id", "kind", "created_at"], name: "index_notifications_on_user_id_and_kind_and_created_at"
    t.index ["user_id", "kind", "notifiable_type", "notifiable_id"], name: "index_notifications_on_user_kind_notifiable_unique", unique: true, where: "((notifiable_type IS NOT NULL) AND (notifiable_id IS NOT NULL))"
    t.index ["user_id", "read_at", "created_at"], name: "index_notifications_on_user_id_and_read_at_and_created_at"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "passkeys", force: :cascade do |t|
    t.boolean "backed_up", default: false, null: false
    t.boolean "backup_eligible", default: false, null: false
    t.datetime "created_at", null: false
    t.string "credential_id", null: false
    t.string "label"
    t.datetime "last_used_at"
    t.text "public_key", null: false
    t.bigint "sign_count", default: 0, null: false
    t.jsonb "transports", default: [], null: false
    t.string "uid", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["credential_id"], name: "index_passkeys_on_credential_id", unique: true
    t.index ["last_used_at"], name: "index_passkeys_on_last_used_at"
    t.index ["uid"], name: "index_passkeys_on_uid", unique: true
    t.index ["user_id"], name: "index_passkeys_on_user_id"
  end

  create_table "receipt_adjustments", force: :cascade do |t|
    t.bigint "amount", null: false
    t.decimal "confidence", precision: 5, scale: 4
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.string "label"
    t.boolean "needs_review", default: false, null: false
    t.integer "position_index"
    t.bigint "receipt_id", null: false
    t.jsonb "review_reasons", default: [], null: false
    t.string "sign", null: false
    t.string "source", null: false
    t.integer "source_line_index"
    t.text "source_text"
    t.decimal "tax_rate", precision: 5, scale: 4
    t.datetime "updated_at", null: false
    t.index ["receipt_id", "kind"], name: "index_receipt_adjustments_on_receipt_id_and_kind"
    t.index ["receipt_id", "position_index"], name: "index_receipt_adjustments_on_receipt_id_and_position_index"
    t.index ["receipt_id"], name: "index_receipt_adjustments_on_receipt_id"
  end

  create_table "receipt_analysis_runs", force: :cascade do |t|
    t.string "ai_fallback_provider"
    t.boolean "ai_fallback_used", default: false, null: false
    t.datetime "ai_finished_at"
    t.jsonb "ai_input_snapshot", default: {}, null: false
    t.integer "ai_latency_ms"
    t.string "ai_model"
    t.jsonb "ai_normalized_result_snapshot", default: {}, null: false
    t.string "ai_provider"
    t.jsonb "ai_result_summary", default: {}, null: false
    t.datetime "ai_started_at"
    t.integer "attempt_number", default: 1, null: false
    t.datetime "created_at", null: false
    t.string "error_code"
    t.text "error_message"
    t.string "error_stage"
    t.datetime "expires_at"
    t.jsonb "final_result_summary", default: {}, null: false
    t.datetime "finalized_at"
    t.datetime "finished_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "ocr_finished_at"
    t.integer "ocr_latency_ms"
    t.string "ocr_model"
    t.string "ocr_provider"
    t.jsonb "ocr_result_snapshot", default: {}, null: false
    t.datetime "ocr_started_at"
    t.jsonb "ocr_summary", default: {}, null: false
    t.bigint "parent_run_id"
    t.bigint "receipt_id", null: false
    t.text "request_reason"
    t.bigint "requested_by_user_id"
    t.string "run_key", null: false
    t.string "source", null: false
    t.string "stage", null: false
    t.datetime "started_at"
    t.string "status", null: false
    t.integer "total_latency_ms"
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_receipt_analysis_runs_on_expires_at"
    t.index ["parent_run_id"], name: "index_receipt_analysis_runs_on_parent_run_id"
    t.index ["receipt_id", "created_at"], name: "index_receipt_analysis_runs_on_receipt_id_and_created_at"
    t.index ["receipt_id"], name: "index_receipt_analysis_runs_on_receipt_id"
    t.index ["receipt_id"], name: "index_receipt_analysis_runs_one_active_per_receipt", unique: true, where: "((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text]))"
    t.index ["requested_by_user_id"], name: "index_receipt_analysis_runs_on_requested_by_user_id"
    t.index ["run_key"], name: "index_receipt_analysis_runs_on_run_key", unique: true
    t.index ["status", "stage"], name: "index_receipt_analysis_runs_on_status_and_stage"
  end

  create_table "receipt_items", force: :cascade do |t|
    t.string "category"
    t.decimal "confidence"
    t.string "confirmed_name"
    t.datetime "created_at", null: false
    t.bigint "discount_amount"
    t.decimal "discount_rate", precision: 5, scale: 3
    t.bigint "line_total"
    t.boolean "needs_review", default: false, null: false
    t.bigint "original_line_total"
    t.integer "position_index"
    t.bigint "price"
    t.string "product_code"
    t.decimal "quantity", precision: 10, scale: 3
    t.string "quantity_unit_code", default: "each", null: false
    t.text "raw_text"
    t.bigint "receipt_id", null: false
    t.jsonb "review_reasons", default: [], null: false
    t.string "suggested_name"
    t.decimal "tax_rate", precision: 5, scale: 4
    t.datetime "updated_at", null: false
    t.index ["receipt_id"], name: "index_receipt_items_on_receipt_id"
  end

  create_table "receipt_payments", force: :cascade do |t|
    t.bigint "amount"
    t.datetime "created_at", null: false
    t.string "method"
    t.bigint "receipt_id", null: false
    t.datetime "updated_at", null: false
    t.index ["receipt_id"], name: "index_receipt_payments_on_receipt_id"
  end

  create_table "receipt_tax_details", force: :cascade do |t|
    t.bigint "amount"
    t.datetime "created_at", null: false
    t.string "description"
    t.bigint "net_amount"
    t.decimal "rate", precision: 5, scale: 4
    t.bigint "receipt_id", null: false
    t.datetime "updated_at", null: false
    t.index ["receipt_id"], name: "index_receipt_tax_details_on_receipt_id"
  end

  create_table "receipts", force: :cascade do |t|
    t.jsonb "amount_calculation_profile", default: {}, null: false
    t.string "country_region"
    t.datetime "created_at", null: false
    t.string "currency_code"
    t.string "display_id", limit: 16, null: false
    t.datetime "image_purge_eligible_at"
    t.datetime "image_purged_at"
    t.string "image_purged_reason"
    t.boolean "keep_image", default: true, null: false
    t.text "memo"
    t.datetime "ocr_completed_at"
    t.string "payment_method"
    t.string "processing_error_code"
    t.text "processing_error_message"
    t.string "public_id", limit: 32, null: false
    t.datetime "purchased_at"
    t.string "receipt_type"
    t.jsonb "review_reasons", default: [], null: false
    t.string "status"
    t.text "store_address"
    t.jsonb "store_address_components", default: {}, null: false
    t.string "store_name"
    t.string "store_phone_number"
    t.bigint "subtotal_amount"
    t.bigint "tax_amount"
    t.decimal "tax_rate", precision: 5, scale: 4
    t.bigint "tip_amount"
    t.bigint "total_amount"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["image_purge_eligible_at", "id"], name: "index_receipts_on_image_purge_eligible_at", where: "((keep_image = false) AND (image_purged_at IS NULL) AND (image_purge_eligible_at IS NOT NULL))"
    t.index ["public_id"], name: "index_receipts_on_public_id", unique: true
    t.index ["user_id", "created_at"], name: "index_receipts_on_user_id_and_created_at_desc", order: { created_at: :desc }
    t.index ["user_id", "display_id"], name: "index_receipts_on_user_id_and_display_id", unique: true
    t.index ["user_id", "status", "purchased_at"], name: "index_receipts_on_user_status_purchased_at"
    t.index ["user_id", "status"], name: "index_receipts_on_user_id_and_status"
    t.index ["user_id"], name: "index_receipts_on_user_id"
    t.check_constraint "image_purged_reason IS NULL OR (image_purged_reason::text = ANY (ARRAY['manual_delete'::character varying::text, 'system_purge'::character varying::text]))", name: "check_receipts_image_purged_reason"
  end

  create_table "recovery_codes", force: :cascade do |t|
    t.string "code_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.bigint "user_id", null: false
    t.index ["code_digest"], name: "index_recovery_codes_on_code_digest", unique: true
    t.index ["user_id"], name: "index_recovery_codes_on_user_id"
  end

  create_table "security_events", force: :cascade do |t|
    t.bigint "actor_user_id"
    t.integer "count", default: 1, null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "field_name"
    t.datetime "first_seen_at", null: false
    t.datetime "ignored_at"
    t.inet "ip_address"
    t.datetime "last_seen_at", null: false
    t.string "matched_rule"
    t.jsonb "metadata", default: {}, null: false
    t.string "method", limit: 16
    t.string "path", limit: 2048
    t.text "payload_excerpt"
    t.string "payload_sha256", limit: 64
    t.string "request_id"
    t.datetime "resolved_at"
    t.string "severity", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent", limit: 1000
    t.index ["actor_user_id"], name: "index_security_events_on_actor_user_id"
    t.index ["event_type", "ip_address", "path", "payload_sha256"], name: "index_security_events_on_aggregation_key"
    t.index ["event_type"], name: "index_security_events_on_event_type"
    t.index ["ignored_at"], name: "index_security_events_on_ignored_at", where: "(ignored_at IS NULL)"
    t.index ["ip_address"], name: "index_security_events_on_ip_address"
    t.index ["last_seen_at"], name: "index_security_events_on_last_seen_at"
    t.index ["payload_sha256"], name: "index_security_events_on_payload_sha256"
    t.index ["request_id"], name: "index_security_events_on_request_id"
    t.index ["resolved_at"], name: "index_security_events_on_resolved_at", where: "(resolved_at IS NULL)"
    t.index ["severity"], name: "index_security_events_on_severity"
  end

  create_table "system_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "updated_by_user_id"
    t.jsonb "value", default: {}, null: false
    t.index ["key"], name: "index_system_settings_on_key", unique: true
    t.index ["updated_at"], name: "index_system_settings_on_updated_at"
    t.index ["updated_by_user_id"], name: "index_system_settings_on_updated_by_user_id"
  end

  create_table "totp_credentials", force: :cascade do |t|
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.integer "last_accepted_time_step"
    t.datetime "last_used_at"
    t.text "totp_secret", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_totp_credentials_on_user_id", unique: true
  end

  create_table "usage_counters", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "period", null: false
    t.datetime "period_start", null: false
    t.datetime "updated_at", null: false
    t.bigint "used_bytes", default: 0, null: false
    t.integer "used_count", default: 0, null: false
    t.bigint "user_id", null: false
    t.index ["key", "period", "period_start"], name: "index_usage_counters_on_key_and_period_and_period_start"
    t.index ["user_id", "key", "period", "period_start"], name: "idx_on_user_id_key_period_period_start_e802a8f1d6", unique: true
    t.index ["user_id"], name: "index_usage_counters_on_user_id"
  end

  create_table "user_limit_overrides", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id"
    t.boolean "enabled", default: true, null: false
    t.datetime "expires_at"
    t.string "key", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "updated_by_user_id"
    t.bigint "user_id", null: false
    t.jsonb "value", default: {}, null: false
    t.index ["created_by_user_id"], name: "index_user_limit_overrides_on_created_by_user_id"
    t.index ["expires_at"], name: "index_user_limit_overrides_on_expires_at"
    t.index ["updated_by_user_id"], name: "index_user_limit_overrides_on_updated_by_user_id"
    t.index ["user_id", "enabled"], name: "index_user_limit_overrides_on_user_id_and_enabled"
    t.index ["user_id", "key"], name: "index_user_limit_overrides_on_user_id_and_key", unique: true
    t.index ["user_id"], name: "index_user_limit_overrides_on_user_id"
  end

  create_table "user_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expired_at"
    t.inet "ip_address"
    t.datetime "last_seen_at", null: false
    t.datetime "revoked_at"
    t.string "session_uid_digest", null: false
    t.integer "session_version", null: false
    t.string "sign_in_method"
    t.datetime "signed_out_at"
    t.datetime "started_at", null: false
    t.datetime "updated_at", null: false
    t.text "user_agent"
    t.bigint "user_id", null: false
    t.index ["last_seen_at"], name: "index_user_sessions_on_last_seen_at"
    t.index ["revoked_at"], name: "index_user_sessions_on_revoked_at"
    t.index ["session_uid_digest"], name: "index_user_sessions_on_session_uid_digest", unique: true
    t.index ["signed_out_at"], name: "index_user_sessions_on_signed_out_at"
    t.index ["user_id"], name: "index_user_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.datetime "confirmation_sent_at"
    t.string "confirmation_token"
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.datetime "current_sign_in_at"
    t.inet "current_sign_in_ip"
    t.boolean "delete_confirmation_enabled", default: true, null: false
    t.string "discount_rounding_mode", default: "round", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.boolean "guest", default: false, null: false
    t.boolean "keep_receipt_images"
    t.datetime "last_sign_in_at"
    t.inet "last_sign_in_ip"
    t.datetime "locked_at"
    t.string "name"
    t.datetime "privacy_accepted_at"
    t.string "privacy_version"
    t.boolean "product_name_ai_completion_enabled", default: false, null: false
    t.boolean "push_notification_enabled", default: true, null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.integer "session_version", default: 0, null: false
    t.integer "sign_in_count", default: 0, null: false
    t.bigint "storage_limit_bytes", default: 1073741824, null: false
    t.string "tax_rounding_mode", default: "floor", null: false
    t.datetime "terms_accepted_at"
    t.string "terms_version"
    t.string "theme_preference", default: "system", null: false
    t.string "unconfirmed_email"
    t.string "unlock_token"
    t.datetime "updated_at", null: false
    t.string "webauthn_id"
    t.index "COALESCE(last_sign_in_at, updated_at)", name: "index_users_on_guest_cleanup_at", where: "((guest = true) AND (confirmed_at IS NOT NULL))"
    t.index "lower((unconfirmed_email)::text)", name: "index_users_on_lower_unconfirmed_email_unique", unique: true, where: "((unconfirmed_email IS NOT NULL) AND ((unconfirmed_email)::text <> ''::text))"
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
    t.index ["webauthn_id"], name: "index_users_on_webauthn_id", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "announcement_links", "announcements"
  add_foreign_key "announcements", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "announcements", "users", column: "updated_by_id", on_delete: :nullify
  add_foreign_key "audit_logs", "users", column: "actor_user_id", on_delete: :nullify
  add_foreign_key "contact_requests", "users", column: "handled_by_user_id", on_delete: :nullify
  add_foreign_key "contact_requests", "users", on_delete: :nullify
  add_foreign_key "notifications", "users"
  add_foreign_key "passkeys", "users"
  add_foreign_key "receipt_adjustments", "receipts"
  add_foreign_key "receipt_analysis_runs", "receipt_analysis_runs", column: "parent_run_id", on_delete: :nullify
  add_foreign_key "receipt_analysis_runs", "receipts"
  add_foreign_key "receipt_analysis_runs", "users", column: "requested_by_user_id", on_delete: :nullify
  add_foreign_key "receipt_items", "receipts"
  add_foreign_key "receipt_payments", "receipts"
  add_foreign_key "receipt_tax_details", "receipts"
  add_foreign_key "receipts", "users"
  add_foreign_key "recovery_codes", "users"
  add_foreign_key "security_events", "users", column: "actor_user_id", on_delete: :nullify
  add_foreign_key "system_settings", "users", column: "updated_by_user_id", on_delete: :nullify
  add_foreign_key "totp_credentials", "users"
  add_foreign_key "usage_counters", "users"
  add_foreign_key "user_limit_overrides", "users"
  add_foreign_key "user_limit_overrides", "users", column: "created_by_user_id", on_delete: :nullify
  add_foreign_key "user_limit_overrides", "users", column: "updated_by_user_id", on_delete: :nullify
  add_foreign_key "user_sessions", "users"
end
