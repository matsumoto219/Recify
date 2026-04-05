class AddReceiptDetailFieldsToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :receipts, :store_address, :text
    add_column :receipts, :store_phone_number, :string
    add_column :receipts, :subtotal_amount, :integer
    add_column :receipts, :tax_amount, :integer
    add_column :receipts, :tax_rate, :integer
  end
end
