class AddDiscountAmountToReceiptItems < ActiveRecord::Migration[8.1]
  def change
    add_column :receipt_items, :discount_amount, :bigint
  end
end
