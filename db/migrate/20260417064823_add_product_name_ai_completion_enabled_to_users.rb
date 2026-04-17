class AddProductNameAiCompletionEnabledToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :product_name_ai_completion_enabled, :boolean, null: false, default: false
  end
end
