require 'rails_helper'

RSpec.describe Receipts::UploadPagePresenter do
  describe '#ocr_down?, #ocr_degraded?, #ai_down?, and #ai_degraded?' do
    it 'normalizes service snapshot state values' do
      presenter = described_class.new(
        user: double('user', storage_usage: double('storage_usage', used_bytes: 0, limit_bytes: 100)),
        ocr_state: { 'state' => 'degraded' },
        ai_state: { state: :down }
      )

      aggregate_failures do
        expect(presenter).not_to be_ocr_down
        expect(presenter).to be_ocr_degraded
        expect(presenter).to be_ocr_available
        expect(presenter).to be_ai_down
        expect(presenter).not_to be_ai_degraded
      end
    end
  end

  describe 'upload limits and storage values' do
    it 'returns display payload values for the upload page' do
      storage_usage = double('storage_usage', used_bytes: 12, limit_bytes: 34)
      user = double('user', storage_usage: storage_usage)

      presenter = described_class.new(user: user, ocr_state: { state: 'ok' }, ai_state: { state: 'ok' })

      aggregate_failures do
        expect(presenter).to be_ocr_available
        expect(presenter.file_count_limit).to eq(ReceiptBatchUploadService.max_files)
        expect(presenter.file_count_limit_message).to eq(
          I18n.t('receipts.new_upload.js.max_files', max: ReceiptBatchUploadService.max_files)
        )
        expect(presenter.multiple_upload_hint).to eq(
          I18n.t('receipts.new_upload.multiple_hint', max: ReceiptBatchUploadService.max_files)
        )
        expect(presenter.storage_used_bytes).to eq(12)
        expect(presenter.storage_limit_bytes).to eq(34)
      end
    end
  end
end
