class CreateUserLimitOverrides < ActiveRecord::Migration[8.1]
  def change
    create_table :user_limit_overrides do |t|
      t.references :user, null: false, foreign_key: true
      t.string :key, null: false
      t.jsonb :value, null: false, default: {}
      t.boolean :enabled, null: false, default: true
      t.datetime :expires_at
      t.references :created_by_user,
                   null: true,
                   foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :updated_by_user,
                   null: true,
                   foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :user_limit_overrides, [ :user_id, :key ], unique: true
    add_index :user_limit_overrides, [ :user_id, :enabled ]
    add_index :user_limit_overrides, :expires_at
  end
end
