class AddOcrCompletedAtToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :receipts, :ocr_completed_at, :datetime
  end
end
