class CreateAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_logs do |t|
      t.references :actor_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :actor_kind, null: false
      t.string :action, null: false
      t.string :target_type
      t.bigint :target_id
      t.string :target_uid
      t.text :reason
      t.string :outcome, null: false
      t.string :error_code
      t.jsonb :metadata, null: false, default: {}
      t.jsonb :before_state, null: false, default: {}
      t.jsonb :after_state, null: false, default: {}
      t.string :request_id
      t.inet :ip_address
      t.text :user_agent

      t.timestamps
    end

    add_index :audit_logs, [ :actor_user_id, :created_at ]
    add_index :audit_logs, [ :action, :created_at ]
    add_index :audit_logs, [ :target_type, :target_id, :created_at ]
    add_index :audit_logs, :target_uid
    add_index :audit_logs, :request_id
    add_index :audit_logs, :created_at
  end
end
