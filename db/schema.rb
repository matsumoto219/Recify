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

ActiveRecord::Schema[8.1].define(version: 2026_05_23_042621) do
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
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["notifiable_type", "notifiable_id"], name: "index_notifications_on_notifiable"
    t.index ["user_id", "kind", "created_at"], name: "index_notifications_on_user_id_and_kind_and_created_at"
    t.index ["user_id", "kind", "notifiable_type", "notifiable_id"], name: "index_notifications_on_user_kind_notifiable_unique", unique: true, where: "((notifiable_type IS NOT NULL) AND (notifiable_id IS NOT NULL))"
    t.index ["user_id", "read_at", "created_at"], name: "index_notifications_on_user_id_and_read_at_and_created_at"
    t.index ["user_id"], name: "index_notifications_on_user_id"
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
    t.string "quantity_unit"
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
    t.string "display_id", limit: 16, null: false
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
    t.string "store_name"
    t.string "store_phone_number"
    t.bigint "subtotal_amount"
    t.bigint "tax_amount"
    t.decimal "tax_rate", precision: 5, scale: 4
    t.bigint "tip_amount"
    t.bigint "total_amount"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["public_id"], name: "index_receipts_on_public_id", unique: true
    t.index ["user_id", "created_at"], name: "index_receipts_on_user_id_and_created_at_desc", order: { created_at: :desc }
    t.index ["user_id", "display_id"], name: "index_receipts_on_user_id_and_display_id", unique: true
    t.index ["user_id", "status", "purchased_at"], name: "index_receipts_on_user_status_purchased_at"
    t.index ["user_id", "status"], name: "index_receipts_on_user_id_and_status"
    t.index ["user_id"], name: "index_receipts_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "confirmation_sent_at"
    t.string "confirmation_token"
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.datetime "current_sign_in_at"
    t.inet "current_sign_in_ip"
    t.boolean "delete_confirmation_enabled", default: true, null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.boolean "guest", default: false, null: false
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
    t.integer "sign_in_count", default: 0, null: false
    t.bigint "storage_limit_bytes", default: 1073741824, null: false
    t.datetime "terms_accepted_at"
    t.string "terms_version"
    t.string "theme_preference", default: "system", null: false
    t.string "unconfirmed_email"
    t.string "unlock_token"
    t.datetime "updated_at", null: false
    t.index "COALESCE(last_sign_in_at, updated_at)", name: "index_users_on_guest_cleanup_at", where: "((guest = true) AND (confirmed_at IS NOT NULL))"
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "notifications", "users"
  add_foreign_key "receipt_items", "receipts"
  add_foreign_key "receipt_payments", "receipts"
  add_foreign_key "receipt_tax_details", "receipts"
  add_foreign_key "receipts", "users"
end
