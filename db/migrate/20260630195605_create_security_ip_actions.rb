# frozen_string_literal: true

class CreateSecurityIpActions < ActiveRecord::Migration[8.1]
  def change
    create_table :security_ip_actions do |t|
      t.inet :ip_address, null: false
      t.string :action_type, null: false
      t.string :source, null: false
      t.string :status, null: false, default: "observed"
      t.string :matched_rule
      t.integer :count, null: false, default: 1
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :expires_at
      t.references :source_security_event, foreign_key: { to_table: :security_events }
      t.references :security_ip_block, foreign_key: true
      t.references :actor_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.text :reason
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :security_ip_actions, :ip_address
    add_index :security_ip_actions, :action_type
    add_index :security_ip_actions, :source
    add_index :security_ip_actions, :status
    add_index :security_ip_actions, :matched_rule
    add_index :security_ip_actions, :expires_at
    add_index :security_ip_actions,
              [ :ip_address, :last_seen_at ],
              name: "index_security_ip_actions_on_ip_and_last_seen"
    add_index :security_ip_actions,
              [ :ip_address, :action_type, :matched_rule, :status, :last_seen_at ],
              name: "index_security_ip_actions_on_aggregation_key"
  end
end
