class CreateAnnouncementLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :announcement_links do |t|
      t.references :announcement, null: false, foreign_key: true
      t.string :label, null: false
      t.string :url, null: false
      t.integer :position, null: false, default: 0
      t.boolean :external, null: false, default: false

      t.timestamps
    end

    add_index :announcement_links, [ :announcement_id, :position ]
  end
end
