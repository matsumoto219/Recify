class AddReviewReasonsToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :receipts, :review_reasons, :jsonb, default: [], null: false
  end
end
