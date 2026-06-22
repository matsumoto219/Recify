class CreateReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :receipts do |t|
      t.references :user, null: false, foreign_key: true, type: :bigint
      t.string :public_id, null: false, limit: 32
      t.string :display_id, null: false, limit: 16
      t.string :store_name
      t.text :store_address
      t.jsonb :store_address_components, default: {}, null: false
      t.string :store_phone_number
      t.datetime :purchased_at
      t.bigint :subtotal_amount
      t.bigint :tax_amount
      t.decimal :tax_rate, precision: 5, scale: 4
      t.bigint :total_amount
      t.bigint :tip_amount
      t.string :country_region
      t.string :receipt_type
      t.string :currency_code
      t.string :payment_method
      t.string :status
      t.text :memo
      t.string :processing_error_code
      t.text :processing_error_message
      t.datetime :ocr_completed_at
      t.jsonb :review_reasons, default: [], null: false
      t.jsonb :amount_calculation_profile, default: {}, null: false
      t.boolean :keep_image, default: true, null: false
      t.datetime :image_purge_eligible_at
      t.datetime :image_purged_at
      t.string :image_purged_reason
      t.string :moderation_status, null: false, default: "active"
      t.datetime :quarantined_at
      t.references :quarantined_by, foreign_key: { to_table: :users }, type: :bigint
      t.text :quarantine_reason
      t.datetime :quarantine_released_at
      t.references :quarantine_released_by, foreign_key: { to_table: :users }, type: :bigint
      t.text :quarantine_released_reason

      t.timestamps
    end

    add_index :receipts, :public_id, unique: true
    add_index :receipts, [ :user_id, :display_id ], unique: true
    add_index :receipts, [ :user_id, :created_at ],
              order: { created_at: :desc },
              name: "index_receipts_on_user_id_and_created_at_desc"
    add_index :receipts, [ :user_id, :status ],
              name: "index_receipts_on_user_id_and_status"
    add_index :receipts, [ :user_id, :status, :purchased_at ],
              name: "index_receipts_on_user_status_purchased_at"
    add_index :receipts, [ :user_id, :moderation_status, :created_at ],
              order: { created_at: :desc },
              name: "index_receipts_on_user_moderation_created_at"
    add_index :receipts, [ :moderation_status, :quarantined_at ],
              name: "index_receipts_on_moderation_status_quarantined_at"
    add_index :receipts,
              [ :image_purge_eligible_at, :id ],
              name: "index_receipts_on_image_purge_eligible_at",
              where: "keep_image = FALSE AND image_purged_at IS NULL AND image_purge_eligible_at IS NOT NULL"
    add_check_constraint :receipts,
                         "image_purged_reason IS NULL OR image_purged_reason IN ('manual_delete', 'system_purge')",
                         name: "check_receipts_image_purged_reason"
    add_check_constraint :receipts,
                         "moderation_status IN ('active', 'quarantined')",
                         name: "check_receipts_moderation_status"
  end
end
