class AddFutureItemFieldsToReceiptItems < ActiveRecord::Migration[8.1]
  def change
    add_column :receipt_items, :quantity_unit, :string
    add_column :receipt_items, :product_code, :string
  end
end
