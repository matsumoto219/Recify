class CreateUsageCounters < ActiveRecord::Migration[8.1]
  def change
    create_table :usage_counters do |t|
      t.references :user, null: false, foreign_key: true
      t.string :key, null: false
      t.string :period, null: false
      t.datetime :period_start, null: false
      t.integer :used_count, null: false, default: 0
      t.bigint :used_bytes, null: false, default: 0
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :usage_counters, [ :user_id, :key, :period, :period_start ], unique: true
    add_index :usage_counters, [ :key, :period, :period_start ]
  end
end
