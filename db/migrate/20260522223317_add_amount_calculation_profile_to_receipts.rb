class AddAmountCalculationProfileToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :receipts, :amount_calculation_profile, :jsonb, default: {}, null: false
  end
end
