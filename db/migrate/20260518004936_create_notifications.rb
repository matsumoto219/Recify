class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications do |t|
      t.references :user, null: false, foreign_key: true
      t.string :kind, null: false
      t.references :notifiable, polymorphic: true, null: true
      t.string :title, null: false
      t.text :body
      t.string :action_path
      t.datetime :read_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :notifications, [ :user_id, :read_at, :created_at ]
    add_index :notifications, [ :user_id, :kind, :created_at ]
  end
end
