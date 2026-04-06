class AddFutureReceiptFieldsToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :receipts, :tip_amount, :integer
    add_column :receipts, :country_region, :string
    add_column :receipts, :receipt_type, :string
  end
end
