class AddUniqueIndexToNotifications < ActiveRecord::Migration[8.1]
  INDEX_NAME = "index_notifications_on_user_kind_notifiable_unique"

  def up
    execute <<~SQL.squish
      DELETE FROM notifications
      WHERE id IN (
        SELECT id
        FROM (
          SELECT
            id,
            ROW_NUMBER() OVER (
              PARTITION BY user_id, kind, notifiable_type, notifiable_id
              ORDER BY created_at ASC, id ASC
            ) AS duplicate_position
          FROM notifications
          WHERE notifiable_type IS NOT NULL
            AND notifiable_id IS NOT NULL
        ) duplicates
        WHERE duplicate_position > 1
      )
    SQL

    add_index :notifications,
      [ :user_id, :kind, :notifiable_type, :notifiable_id ],
      unique: true,
      where: "notifiable_type IS NOT NULL AND notifiable_id IS NOT NULL",
      name: INDEX_NAME
  end

  def down
    remove_index :notifications, name: INDEX_NAME
  end
end
