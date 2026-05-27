class CreateContactRequests < ActiveRecord::Migration[8.0]
  def change
    create_table :contact_requests do |t|
      t.references :user, null: true, foreign_key: { on_delete: :nullify }
      t.string :request_uid, null: false
      t.string :email, null: false
      t.string :email_digest, null: false
      t.string :category, null: false
      t.string :subject, null: false
      t.text :body, null: false
      t.string :status, null: false, default: "open"
      t.string :source, null: false
      t.inet :ip_address
      t.text :user_agent
      t.string :request_id
      t.references :handled_by_user,
                   null: true,
                   foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :handled_at

      t.timestamps
    end

    add_index :contact_requests, :request_uid, unique: true
    add_index :contact_requests, :status
    add_index :contact_requests, :category
    add_index :contact_requests, :email_digest
    add_index :contact_requests, :created_at
  end
end
