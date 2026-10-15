class CreateReceiptRegistrationOperations < ActiveRecord::Migration[8.1]
  def up
    create_table :receipt_registration_operations do |t|
      t.references :user, null: false, foreign_key: true
      t.string :operation_key, limit: 64, null: false
      t.string :kind, limit: 16, null: false
      t.string :state, limit: 16, null: false
      t.string :input_fingerprint, limit: 64, null: false
      t.string :attempt_key, limit: 32, null: false
      t.boolean :notification_reported, null: false, default: false
      t.datetime :issued_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.bigint :receipt_ids, array: true, null: false, default: []

      t.timestamps
    end

    add_index :receipt_registration_operations, [ :user_id, :operation_key ], unique: true,
              name: "index_receipt_registration_operations_on_owner_and_key"
    add_index :receipt_registration_operations, :expires_at
    add_check_constraint :receipt_registration_operations,
                         "kind IN ('upload', 'batch_upload', 'manual')",
                         name: "check_receipt_registration_operation_kind"
    add_check_constraint :receipt_registration_operations,
                         "state IN ('processing', 'accepted', 'failed')",
                         name: "check_receipt_registration_operation_state"
    add_check_constraint :receipt_registration_operations,
                         <<~SQL.squish,
                           operation_key ~ '^[0-9a-f]{64}$' AND
                           input_fingerprint ~ '^[0-9a-f]{64}$' AND
                           attempt_key ~ '^[0-9a-f]{32}$'
                         SQL
                         name: "check_receipt_registration_operation_identifiers"
    add_check_constraint :receipt_registration_operations,
                         "expires_at = issued_at + interval '24 hours'",
                         name: "check_receipt_registration_operation_lifetime"
    add_check_constraint :receipt_registration_operations,
                         <<~SQL.squish,
                           array_ndims(receipt_ids) IS NULL OR (
                             array_ndims(receipt_ids) = 1 AND
                             array_length(receipt_ids, 1) BETWEEN 1 AND 20 AND
                             array_position(receipt_ids, NULL) IS NULL AND
                             0 < ALL(receipt_ids)
                           )
                         SQL
                         name: "check_receipt_registration_operation_receipt_ids"
    add_check_constraint :receipt_registration_operations,
                         <<~SQL.squish,
                           (state = 'accepted' AND accepted_at IS NOT NULL AND
                             cardinality(receipt_ids) BETWEEN 1 AND CASE WHEN kind = 'batch_upload' THEN 20 ELSE 1 END)
                           OR
                           (state <> 'accepted' AND accepted_at IS NULL AND cardinality(receipt_ids) = 0)
                         SQL
                         name: "check_receipt_registration_operation_acceptance"
  end

  def down
    if select_value("SELECT 1 FROM receipt_registration_operations LIMIT 1")
      raise ActiveRecord::IrreversibleMigration,
        "registration operations must finish their retention lifecycle before rollback"
    end

    drop_table :receipt_registration_operations
  end
end
