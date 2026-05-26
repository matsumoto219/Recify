class CreatePasskeys < ActiveRecord::Migration[8.1]
  def change
    create_table :passkeys do |t|
      t.references :user, null: false, foreign_key: true
      t.string :credential_id, null: false
      t.text :public_key, null: false
      t.bigint :sign_count, null: false, default: 0
      t.string :label
      t.jsonb :transports, null: false, default: []
      t.boolean :backup_eligible, null: false, default: false
      t.boolean :backed_up, null: false, default: false
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :passkeys, :credential_id, unique: true
    add_index :passkeys, :last_used_at
  end
end
