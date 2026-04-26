class AddDiscountFieldsToReceiptItems < ActiveRecord::Migration[8.1]
  def change
    add_column :receipt_items, :original_line_total, :integer
    add_column :receipt_items, :discount_rate, :decimal, precision: 5, scale: 3
  end
end
