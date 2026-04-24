class AddTaxRateToReceiptItems < ActiveRecord::Migration[8.1]
  def change
    add_column :receipt_items, :tax_rate, :decimal, precision: 5, scale: 4
  end
end
