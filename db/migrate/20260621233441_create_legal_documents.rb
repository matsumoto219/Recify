# frozen_string_literal: true

class CreateLegalDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :legal_documents do |t|
      t.string :document_type, null: false
      t.string :version, null: false
      t.string :locale, null: false, default: "ja"
      t.string :title, null: false
      t.string :source_path, null: false
      t.date :effective_on, null: false
      t.date :published_on, null: false
      t.date :last_updated_on, null: false
      t.boolean :reconsent_required, null: false, default: true
      t.boolean :current, null: false, default: false
      t.string :status, null: false, default: "published"
      t.string :content_digest, null: false

      t.timestamps null: false
    end

    add_index :legal_documents,
              %i[document_type version locale],
              unique: true,
              name: "index_legal_documents_on_type_version_locale"
    add_index :legal_documents,
              %i[document_type locale],
              unique: true,
              where: "\"current\" = TRUE",
              name: "index_legal_documents_one_current_per_type_locale"
    add_index :legal_documents,
              %i[document_type locale status],
              name: "index_legal_documents_on_type_locale_status"
    add_index :legal_documents,
              :source_path,
              unique: true,
              name: "index_legal_documents_on_source_path"
  end
end
