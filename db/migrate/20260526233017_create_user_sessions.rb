class CreateUserSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :user_sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :session_uid_digest, null: false
      t.integer :session_version, null: false
      t.datetime :started_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :signed_out_at
      t.datetime :revoked_at
      t.datetime :expired_at
      t.inet :ip_address
      t.text :user_agent
      t.string :sign_in_method

      t.timestamps
    end

    add_index :user_sessions, :session_uid_digest, unique: true
    add_index :user_sessions, :last_seen_at
    add_index :user_sessions, :revoked_at
    add_index :user_sessions, :signed_out_at
  end
end
