class CreateReceiptPayments < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_payments do |t|
      t.references :receipt, null: false, foreign_key: true, type: :bigint
      t.string :method
      t.bigint :amount

      t.timestamps
    end
  end
end
