class CreateReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :receipts do |t|
      t.references :user, null: false, foreign_key: true
      t.string :store_name
      t.datetime :purchased_at
      t.integer :total_amount
      t.string :payment_method
      t.string :status
      t.text :memo

      t.timestamps
    end
  end
end
