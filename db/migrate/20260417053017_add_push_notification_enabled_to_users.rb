class AddPushNotificationEnabledToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :push_notification_enabled, :boolean, null: false, default: true
  end
end
