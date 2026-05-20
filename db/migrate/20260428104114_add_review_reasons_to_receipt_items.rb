class AddReviewReasonsToReceiptItems < ActiveRecord::Migration[8.1]
  def change
    add_column :receipt_items, :review_reasons, :jsonb, default: [], null: false
  end
end
