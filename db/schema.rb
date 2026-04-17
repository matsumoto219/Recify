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

ActiveRecord::Schema[8.1].define(version: 2026_04_17_053017) do
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

  create_table "receipt_items", force: :cascade do |t|
    t.string "category"
    t.decimal "confidence"
    t.string "confirmed_name"
    t.datetime "created_at", null: false
    t.integer "line_total"
    t.boolean "needs_review"
    t.integer "position_index"
    t.integer "price"
    t.string "product_code"
    t.integer "quantity"
    t.string "quantity_unit"
    t.text "raw_text"
    t.integer "receipt_id", null: false
    t.string "suggested_name"
    t.datetime "updated_at", null: false
    t.index ["receipt_id"], name: "index_receipt_items_on_receipt_id"
  end

  create_table "receipt_payments", force: :cascade do |t|
    t.integer "amount"
    t.datetime "created_at", null: false
    t.string "method"
    t.integer "receipt_id", null: false
    t.datetime "updated_at", null: false
    t.index ["receipt_id"], name: "index_receipt_payments_on_receipt_id"
  end

  create_table "receipt_tax_details", force: :cascade do |t|
    t.integer "amount"
    t.datetime "created_at", null: false
    t.string "description"
    t.integer "net_amount"
    t.decimal "rate"
    t.integer "receipt_id", null: false
    t.datetime "updated_at", null: false
    t.index ["receipt_id"], name: "index_receipt_tax_details_on_receipt_id"
  end

  create_table "receipts", force: :cascade do |t|
    t.string "country_region"
    t.datetime "created_at", null: false
    t.text "memo"
    t.datetime "ocr_completed_at"
    t.string "payment_method"
    t.string "processing_error_code"
    t.text "processing_error_message"
    t.datetime "purchased_at"
    t.string "receipt_type"
    t.json "review_reasons"
    t.string "status"
    t.text "store_address"
    t.string "store_name"
    t.string "store_phone_number"
    t.integer "subtotal_amount"
    t.integer "tax_amount"
    t.decimal "tax_rate", precision: 5, scale: 4
    t.integer "tip_amount"
    t.integer "total_amount"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_receipts_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.boolean "guest"
    t.string "name"
    t.boolean "push_notification_enabled", default: false, null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "receipt_items", "receipts"
  add_foreign_key "receipt_payments", "receipts"
  add_foreign_key "receipt_tax_details", "receipts"
  add_foreign_key "receipts", "users"
end
