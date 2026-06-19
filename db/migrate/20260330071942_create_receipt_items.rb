class CreateReceiptItems < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_items do |t|
      t.references :receipt, null: false, foreign_key: true, type: :bigint
      t.text :raw_text
      t.string :suggested_name
      t.string :confirmed_name
      t.string :category
      t.bigint :price
      t.decimal :quantity, precision: 10, scale: 3
      t.string :quantity_unit_code, null: false, default: "each"
      t.string :product_code
      t.bigint :original_line_total
      t.bigint :line_total
      t.bigint :discount_amount
      t.decimal :discount_rate, precision: 5, scale: 3
      t.decimal :tax_rate, precision: 5, scale: 4
      t.boolean :needs_review, default: false, null: false
      t.jsonb :review_reasons, default: [], null: false
      t.integer :position_index
      t.decimal :confidence

      t.timestamps
    end
  end
end
