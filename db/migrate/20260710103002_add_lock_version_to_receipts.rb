# frozen_string_literal: true

class AddLockVersionToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :receipts, :lock_version, :integer, null: false, default: 0
  end
end
