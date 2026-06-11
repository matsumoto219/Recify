class CreateReceiptAnalysisRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_analysis_runs do |t|
      t.references :receipt, null: false, foreign_key: true
      t.string :run_key, null: false
      t.string :source, null: false
      t.string :stage, null: false
      t.string :status, null: false
      t.references :requested_by_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.text :request_reason
      t.integer :attempt_number, null: false, default: 1
      t.bigint :parent_run_id
      t.string :ocr_provider
      t.string :ocr_model
      t.string :ai_provider
      t.string :ai_model
      t.string :ai_fallback_provider
      t.boolean :ai_fallback_used, null: false, default: false
      t.integer :ocr_latency_ms
      t.integer :ai_latency_ms
      t.integer :total_latency_ms
      t.string :error_stage
      t.string :error_code
      t.text :error_message
      t.jsonb :ocr_summary, null: false, default: {}
      t.jsonb :ocr_result_snapshot, null: false, default: {}
      t.jsonb :ai_input_snapshot, null: false, default: {}
      t.jsonb :ai_result_summary, null: false, default: {}
      t.jsonb :ai_normalized_result_snapshot, null: false, default: {}
      t.jsonb :final_result_summary, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.datetime :started_at
      t.datetime :ocr_started_at
      t.datetime :ocr_finished_at
      t.datetime :ai_started_at
      t.datetime :ai_finished_at
      t.datetime :finalized_at
      t.datetime :finished_at
      t.datetime :expires_at

      t.timestamps
    end

    add_foreign_key :receipt_analysis_runs, :receipt_analysis_runs, column: :parent_run_id, on_delete: :nullify

    add_index :receipt_analysis_runs, :run_key, unique: true
    add_index :receipt_analysis_runs, [ :receipt_id, :created_at ]
    add_index :receipt_analysis_runs, [ :status, :stage ]
    add_index :receipt_analysis_runs, :expires_at
    add_index :receipt_analysis_runs, :parent_run_id
    add_index :receipt_analysis_runs,
              :receipt_id,
              unique: true,
              where: "status IN ('queued', 'running')",
              name: "index_receipt_analysis_runs_one_active_per_receipt"
  end
end
