class CreateReceiptPayments < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_payments do |t|
      t.references :receipt, null: false, foreign_key: true
      t.string :method
      t.integer :amount

      t.timestamps
    end
  end
end
