class ChangeQuantityToDecimalInReceiptItems < ActiveRecord::Migration[8.1]
  def change
    change_column :receipt_items, :quantity, :decimal, precision: 10, scale: 3
  end
end
