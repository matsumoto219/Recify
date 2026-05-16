class AddReceiptItemDeleteConfirmationEnabledToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users,
      :receipt_item_delete_confirmation_enabled,
      :boolean,
      null: false,
      default: true
  end
end
