class CreateAnnouncements < ActiveRecord::Migration[8.1]
  def change
    create_table :announcements do |t|
      t.string :public_id, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.string :image_alt_text
      t.string :status, null: false, default: "draft"
      t.string :kind, null: false, default: "general"
      t.boolean :pinned, null: false, default: false
      t.integer :priority, null: false, default: 0
      t.datetime :published_at
      t.datetime :starts_at
      t.datetime :ends_at
      t.references :created_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :updated_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }

      t.timestamps
    end

    add_index :announcements, :public_id, unique: true
    add_index :announcements, :status
    add_index :announcements, :kind
    add_index :announcements, :published_at
    add_index :announcements, :starts_at
    add_index :announcements, :ends_at
    add_index :announcements,
              [ :status, :pinned, :priority, :published_at ],
              name: "index_announcements_public_order"
  end
end
