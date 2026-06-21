require "set"

class AddUidsToNotificationsAndPasskeys < ActiveRecord::Migration[8.1]
  UID_RANDOM_LENGTH = 16
  UID_RETRY_LIMIT = 20

  def up
    add_column :notifications, :uid, :string, limit: 32
    add_column :passkeys, :uid, :string, limit: 32

    backfill_uid(:notifications, "ntf_")
    backfill_uid(:passkeys, "psk_")

    change_column_null :notifications, :uid, false
    change_column_null :passkeys, :uid, false

    add_index :notifications, :uid, unique: true
    add_index :passkeys, :uid, unique: true
  end

  def down
    remove_index :passkeys, :uid
    remove_index :notifications, :uid
    remove_column :passkeys, :uid
    remove_column :notifications, :uid
  end

  private

  def backfill_uid(table_name, prefix)
    quoted_table = quote_table_name(table_name)
    existing_uids = Set.new(select_values("SELECT uid FROM #{quoted_table} WHERE uid IS NOT NULL"))

    select_values("SELECT id FROM #{quoted_table} WHERE uid IS NULL ORDER BY id ASC").each do |id|
      uid = unique_uid(prefix, existing_uids)
      existing_uids << uid

      execute <<~SQL.squish
        UPDATE #{quoted_table}
        SET uid = #{quote(uid)}
        WHERE id = #{id.to_i}
      SQL
    end
  end

  def unique_uid(prefix, existing_uids)
    UID_RETRY_LIMIT.times do
      candidate = "#{prefix}#{SecureRandom.base58(UID_RANDOM_LENGTH)}"
      return candidate unless existing_uids.include?(candidate)
    end

    raise ActiveRecord::RecordNotUnique, "Could not generate unique #{prefix} uid"
  end
end
