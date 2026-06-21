# frozen_string_literal: true

class CreateLegalAcceptances < ActiveRecord::Migration[8.1]
  def change
    create_table :legal_acceptances do |t|
      t.references :user, null: false, foreign_key: true
      t.references :legal_document, null: false, foreign_key: true
      t.string :document_type, null: false
      t.string :version, null: false
      t.string :locale, null: false, default: "ja"
      t.datetime :accepted_at, null: false
      t.string :acceptance_context, null: false
      t.inet :ip_address
      t.string :user_agent, limit: 512
      t.string :request_id, limit: 128

      t.timestamps null: false
    end

    add_index :legal_acceptances,
              %i[user_id legal_document_id],
              unique: true,
              name: "index_legal_acceptances_on_user_and_document"
    add_index :legal_acceptances,
              %i[user_id document_type version locale],
              unique: true,
              name: "index_legal_acceptances_on_user_type_version_locale"
    add_index :legal_acceptances,
              %i[document_type version locale],
              name: "index_legal_acceptances_on_type_version_locale"
    add_index :legal_acceptances,
              :accepted_at,
              name: "index_legal_acceptances_on_accepted_at"
  end
end
