class AddNormalizedSnapshotsToReceiptAnalysisRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :receipt_analysis_runs, :ocr_result_snapshot, :jsonb, null: false, default: {}
    add_column :receipt_analysis_runs, :ai_normalized_result_snapshot, :jsonb, null: false, default: {}
  end
end
