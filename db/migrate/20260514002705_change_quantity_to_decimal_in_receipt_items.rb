class ChangeQuantityToDecimalInReceiptItems < ActiveRecord::Migration[8.1]
  def up
    change_column :receipt_items, :quantity, :decimal, precision: 10, scale: 3
  end

  def down
    change_column :receipt_items, :quantity, :integer
  end
end
