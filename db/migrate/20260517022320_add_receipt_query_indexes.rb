class AddReceiptQueryIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :receipts, [ :user_id, :created_at ],
      order: { created_at: :desc },
      name: "index_receipts_on_user_id_and_created_at_desc",
      if_not_exists: true

    add_index :receipts, [ :user_id, :status ],
      name: "index_receipts_on_user_id_and_status",
      if_not_exists: true

    add_index :receipts, [ :user_id, :status, :purchased_at ],
      name: "index_receipts_on_user_status_purchased_at",
      if_not_exists: true
  end
end
