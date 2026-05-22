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

      t.timestamps
    end

    add_index :receipts, :public_id, unique: true
    add_index :receipts, [ :user_id, :display_id ], unique: true
  end
end
