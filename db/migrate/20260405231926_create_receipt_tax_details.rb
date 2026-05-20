class CreateReceiptTaxDetails < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_tax_details do |t|
      t.references :receipt, null: false, foreign_key: true, type: :bigint
      t.string :description
      t.bigint :amount
      t.decimal :rate, precision: 5, scale: 4
      t.bigint :net_amount

      t.timestamps
    end
  end
end
