class ChangeTaxRateToDecimalInReceipts < ActiveRecord::Migration[8.1]
  def up
    change_column :receipts, :tax_rate, :decimal, precision: 5, scale: 4
  end

  def down
    change_column :receipts, :tax_rate, :integer
  end
end
