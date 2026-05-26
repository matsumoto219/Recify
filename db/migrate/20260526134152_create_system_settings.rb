class CreateSystemSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :system_settings do |t|
      t.string :key, null: false
      t.jsonb :value, null: false, default: {}
      t.references :updated_by_user,
                   null: true,
                   foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :system_settings, :key, unique: true
    add_index :system_settings, :updated_at
  end
end
