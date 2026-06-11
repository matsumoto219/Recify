# frozen_string_literal: true

class DeviseCreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      ## Database authenticatable
      t.string :email,              null: false, default: ""
      t.string :encrypted_password, null: false, default: ""

      ## Recoverable
      t.string   :reset_password_token
      t.datetime :reset_password_sent_at

      ## Rememberable
      t.datetime :remember_created_at

      ## Trackable
      t.integer  :sign_in_count, default: 0, null: false
      t.datetime :current_sign_in_at
      t.datetime :last_sign_in_at
      t.inet     :current_sign_in_ip
      t.inet     :last_sign_in_ip

      ## Confirmable
      t.string   :confirmation_token
      t.datetime :confirmed_at
      t.datetime :confirmation_sent_at
      t.string   :unconfirmed_email

      ## Lockable
      t.integer  :failed_attempts, default: 0, null: false
      t.string   :unlock_token
      t.datetime :locked_at

      ## Profile
      t.string :name

      ## Guest
      t.boolean :guest, default: false, null: false

      ## Amount calculation settings
      t.string :tax_rounding_mode, null: false, default: "floor"
      t.string :discount_rounding_mode, null: false, default: "round"

      ## Receipt image retention settings
      t.boolean :keep_receipt_images
      t.bigint :storage_limit_bytes, null: false, default: 1.gigabyte

      ## User preferences
      t.boolean :push_notification_enabled, null: false, default: true
      t.boolean :product_name_ai_completion_enabled, null: false, default: false
      t.string :theme_preference, null: false, default: "system"
      t.boolean :delete_confirmation_enabled, null: false, default: true

      ## Legal acceptance
      t.datetime :terms_accepted_at
      t.string :terms_version
      t.datetime :privacy_accepted_at
      t.string :privacy_version

      ## Admin / security
      t.boolean :admin, null: false, default: false
      t.string :webauthn_id
      t.integer :session_version, null: false, default: 0

      t.timestamps null: false
    end

    add_index :users, :email,                unique: true
    add_index :users, :reset_password_token, unique: true
    add_index :users, :confirmation_token,   unique: true
    add_index :users, :unlock_token,         unique: true
    add_index :users, :webauthn_id, unique: true
    add_index :users,
              "LOWER(unconfirmed_email)",
              unique: true,
              where: "unconfirmed_email IS NOT NULL AND unconfirmed_email <> ''",
              name: "index_users_on_lower_unconfirmed_email_unique"
    add_index :users,
      "COALESCE(last_sign_in_at, updated_at)",
      name: "index_users_on_guest_cleanup_at",
      where: "guest = TRUE AND confirmed_at IS NOT NULL"
  end
end
