class AddReviewReasonsToReceiptItems < ActiveRecord::Migration[8.1]
  def change
    add_column :receipt_items, :review_reasons, :json, default: [], null: false
  end
end
