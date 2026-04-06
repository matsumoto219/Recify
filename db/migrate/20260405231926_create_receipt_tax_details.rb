class CreateReceiptTaxDetails < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_tax_details do |t|
      t.references :receipt, null: false, foreign_key: true
      t.string :description
      t.integer :amount
      t.decimal :rate
      t.integer :net_amount

      t.timestamps
    end
  end
end
