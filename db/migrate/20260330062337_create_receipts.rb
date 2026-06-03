class CreateReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :receipts do |t|
      t.references :user, null: false, foreign_key: true, type: :bigint
      t.string :public_id, null: false, limit: 32
      t.string :display_id, null: false, limit: 16
      t.string :store_name
      t.datetime :purchased_at
      t.bigint :total_amount
      t.string :payment_method
      t.string :status
      t.text :memo
      t.boolean :keep_image, default: true, null: false
      t.datetime :image_purge_eligible_at
      t.datetime :image_purged_at
      t.string :image_purged_reason

      t.timestamps
    end

    add_index :receipts, :public_id, unique: true
    add_index :receipts, [ :user_id, :display_id ], unique: true
    add_index :receipts,
              [ :image_purge_eligible_at, :id ],
              name: "index_receipts_on_image_purge_eligible_at",
              where: "keep_image = FALSE AND image_purged_at IS NULL AND image_purge_eligible_at IS NOT NULL"
    add_check_constraint :receipts,
                         "image_purged_reason IS NULL OR image_purged_reason IN ('manual_delete', 'system_purge')",
                         name: "check_receipts_image_purged_reason"
  end
end
