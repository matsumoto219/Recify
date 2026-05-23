# frozen_string_literal: true

class AddLegalAcceptanceToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :terms_accepted_at, :datetime
    add_column :users, :terms_version, :string
    add_column :users, :privacy_accepted_at, :datetime
    add_column :users, :privacy_version, :string
  end
end
