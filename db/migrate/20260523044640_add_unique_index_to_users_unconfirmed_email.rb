# frozen_string_literal: true

class AddUniqueIndexToUsersUnconfirmedEmail < ActiveRecord::Migration[8.1]
  def change
    add_index :users,
              "LOWER(unconfirmed_email)",
              unique: true,
              where: "unconfirmed_email IS NOT NULL AND unconfirmed_email <> ''",
              name: "index_users_on_lower_unconfirmed_email_unique"
  end
end
