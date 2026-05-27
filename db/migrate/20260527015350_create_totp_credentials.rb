class CreateTotpCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :totp_credentials do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.text :totp_secret, null: false
      t.datetime :confirmed_at
      t.datetime :last_used_at
      t.integer :last_accepted_time_step

      t.timestamps
    end
  end
end
