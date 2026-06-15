class CreateSecurityEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :security_events do |t|
      t.string :event_type, null: false
      t.string :severity, null: false
      t.references :actor_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.inet :ip_address
      t.string :user_agent, limit: 1000
      t.string :request_id
      t.string :path, limit: 2048
      t.string :method, limit: 16
      t.string :field_name
      t.string :matched_rule
      t.text :payload_excerpt
      t.string :payload_sha256, limit: 64
      t.integer :count, null: false, default: 1
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :resolved_at
      t.datetime :ignored_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :security_events, :event_type
    add_index :security_events, :severity
    add_index :security_events, :ip_address
    add_index :security_events, :request_id
    add_index :security_events, :payload_sha256
    add_index :security_events, :last_seen_at
    add_index :security_events, :resolved_at, where: "resolved_at IS NULL"
    add_index :security_events, :ignored_at, where: "ignored_at IS NULL"
    add_index :security_events,
              [ :event_type, :ip_address, :path, :payload_sha256 ],
              name: "index_security_events_on_aggregation_key"
  end
end
