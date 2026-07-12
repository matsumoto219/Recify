require 'rails_helper'

RSpec.describe Receipts::Processing::Runs::OcrResponseArtifact do
  let(:run) { create(:receipt_analysis_run, :running, attempt_number: 2) }
  let(:raw_body) do
    JSON.generate(
      'status' => 'succeeded',
      'modelId' => 'prebuilt-receipt',
      'analyzeResult' => {
        'content' => "テストストア\n合計 1000"
      }
    )
  end

  def enable_capture!
    create(:system_setting, key: 'analysis_artifact.ocr_raw_response_capture_enabled', value: SystemSettings.stored_value(true))
  end

  describe '.capture' do
    it '設定OFFでは保存しない' do
      result = described_class.capture(run, raw_body, provider: 'azure_document_intelligence', model_id: 'prebuilt-receipt')

      aggregate_failures do
        expect(result).to be_skipped
        expect(result.reason).to eq('disabled')
        expect(run.reload.ocr_response_artifact).not_to be_attached
      end
    end

    it '設定ONならraw JSONをActiveStorageへ保存しDB snapshotには混ぜない' do
      enable_capture!

      result = described_class.capture(run, raw_body, provider: 'azure_document_intelligence', model_id: 'prebuilt-receipt')
      attachment = run.reload.ocr_response_artifact

      aggregate_failures do
        expect(result).to be_saved
        expect(attachment).to be_attached
        expect(attachment.download.bytes).to eq(raw_body.bytes)
        expect(attachment.blob.filename.to_s).to include(run.run_key)
        expect(attachment.blob.filename.to_s).to include('attempt02')
        expect(attachment.blob.content_type).to eq('application/json')
        expect(attachment.blob.metadata).to include(
          'provider' => 'azure_document_intelligence',
          'model_id' => 'prebuilt-receipt',
          'schema_version' => 1
        )
        expect(run.reload.ocr_result_snapshot.to_json).not_to include('analyzeResult')
        expect(run.ocr_summary.to_json).not_to include('analyzeResult')
      end
    end

    it '既に保存済みなら上書きしない' do
      enable_capture!
      described_class.capture(run, raw_body, provider: 'azure_document_intelligence', model_id: 'prebuilt-receipt')

      result = described_class.capture(run.reload, JSON.generate('status' => 'succeeded', 'changed' => true), provider: 'azure_document_intelligence')

      aggregate_failures do
        expect(result).to be_skipped
        expect(result.reason).to eq('already_attached')
        expect(run.reload.ocr_response_artifact.download.bytes).to eq(raw_body.bytes)
      end
    end

    it 'サイズ上限を超えるJSONは保存しない' do
      enable_capture!
      create(:system_setting, key: 'analysis_artifact.ocr_raw_response_max_bytes', value: SystemSettings.stored_value(64.kilobytes))
      oversized_body = JSON.generate('status' => 'succeeded', 'content' => 'a' * 64.kilobytes)

      result = described_class.capture(run, oversized_body, provider: 'azure_document_intelligence')

      aggregate_failures do
        expect(result).to be_skipped
        expect(result.reason).to eq('too_large')
        expect(run.reload.ocr_response_artifact).not_to be_attached
      end
    end

    it 'global storage quotaに入らないJSONは保存しない' do
      enable_capture!
      allow(Storage).to receive(:global_quota_can_add?).and_return(false)

      result = described_class.capture(run, raw_body, provider: 'azure_document_intelligence')

      aggregate_failures do
        expect(result).to be_skipped
        expect(result.reason).to eq('global_storage_quota_exceeded')
        expect(run.reload.ocr_response_artifact).not_to be_attached
      end
    end

    it 'JSONとして壊れた文字列は保存しない' do
      enable_capture!

      result = described_class.capture(run, 'not json', provider: 'azure_document_intelligence')

      aggregate_failures do
        expect(result).to be_skipped
        expect(result.reason).to eq('blank')
        expect(run.reload.ocr_response_artifact).not_to be_attached
      end
    end
  end

  describe '.purge_expired' do
    it '保持期限を過ぎたOCR response artifactだけpurgeする' do
      enable_capture!
      old_run = create(:receipt_analysis_run, :succeeded)
      fresh_run = create(:receipt_analysis_run, :succeeded)
      described_class.capture(old_run, raw_body, provider: 'azure_document_intelligence')
      described_class.capture(fresh_run, raw_body, provider: 'azure_document_intelligence')
      old_attachment = old_run.reload.ocr_response_artifact.attachment
      old_attachment.update!(created_at: 8.days.ago)

      result = described_class.purge_expired(cutoff: 7.days.ago, limit: 10, dry_run: false)

      aggregate_failures do
        expect(result[:expired_artifact_count]).to eq(1)
        expect(result[:purged_artifact_count]).to eq(1)
        expect(old_run.reload.ocr_response_artifact).not_to be_attached
        expect(fresh_run.reload.ocr_response_artifact).to be_attached
      end
    end
  end
end
