class AddDeleteConfirmationEnabledToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users,
      :delete_confirmation_enabled,
      :boolean,
      null: false,
      default: true
  end
end
