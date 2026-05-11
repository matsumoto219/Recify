class AddThemePreferenceToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :theme_preference, :string, null: false, default: "system"
  end
end
