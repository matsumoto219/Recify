class AddProcessingErrorCodeToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :receipts, :processing_error_code, :string
  end
end
