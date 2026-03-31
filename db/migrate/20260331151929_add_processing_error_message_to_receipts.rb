class AddProcessingErrorMessageToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :receipts, :processing_error_message, :text
  end
end
