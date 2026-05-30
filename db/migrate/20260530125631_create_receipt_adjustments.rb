class CreateReceiptAdjustments < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_adjustments do |t|
      t.references :receipt, null: false, foreign_key: true, type: :bigint
      t.string :kind, null: false
      t.string :label
      t.bigint :amount, null: false
      t.string :sign, null: false
      t.decimal :tax_rate, precision: 5, scale: 4
      t.string :source, null: false
      t.text :source_text
      t.integer :source_line_index
      t.decimal :confidence, precision: 5, scale: 4
      t.boolean :needs_review, null: false, default: false
      t.jsonb :review_reasons, null: false, default: []
      t.integer :position_index

      t.timestamps
    end

    add_index :receipt_adjustments, [ :receipt_id, :position_index ]
    add_index :receipt_adjustments, [ :receipt_id, :kind ]
  end
end
