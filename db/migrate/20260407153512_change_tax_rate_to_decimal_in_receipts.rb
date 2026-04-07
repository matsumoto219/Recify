class ChangeTaxRateToDecimalInReceipts < ActiveRecord::Migration[8.1]
  def change
    change_column :receipts, :tax_rate, :decimal, precision: 5, scale: 4
  end
end
