class CreateReceiptItems < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_items do |t|
      t.references :receipt, null: false, foreign_key: true, type: :bigint
      t.text :raw_text
      t.string :suggested_name
      t.string :confirmed_name
      t.string :category
      t.bigint :price
      t.integer :quantity
      t.bigint :line_total
      t.boolean :needs_review, default: false, null: false
      t.integer :position_index
      t.decimal :confidence

      t.timestamps
    end
  end
end
