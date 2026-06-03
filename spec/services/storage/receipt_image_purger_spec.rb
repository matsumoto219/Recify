require 'rails_helper'

RSpec.describe Storage::ReceiptImagePurger, type: :service do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-06-03 02:00:00')) { example.run }
  end

  def purgeable_receipt(attributes = {})
    create(
      :receipt,
      :completed,
      :with_image,
      {
        keep_image: false,
        image_purge_eligible_at: 1.hour.ago
      }.merge(attributes)
    )
  end

  describe '.call' do
    it 'default dry_runでは対象を返すだけで画像を削除しない' do
      receipt = purgeable_receipt
      blob = receipt.image.blob

      result = described_class.call

      aggregate_failures do
        expect(result).to include(
          dry_run: true,
          candidate_count: 1,
          purged_count: 0,
          skipped_count: 1,
          failed_count: 0
        )
        expect(result[:sample_receipt_ids]).to eq([ receipt.id ])
        expect(receipt.reload.image).to be_attached
        expect(ActiveStorage::Blob.exists?(blob.id)).to eq(true)
        expect(receipt.image_purged_at).to be_nil
      end
    end

    it 'dry_run:falseで対象画像をpurgeしsystem_purgeとして記録する' do
      receipt = purgeable_receipt
      blob = receipt.image.blob

      result = described_class.call(dry_run: false)

      aggregate_failures do
        expect(result).to include(
          dry_run: false,
          candidate_count: 1,
          purged_count: 1,
          skipped_count: 0,
          failed_count: 0
        )
        expect(receipt.reload.image).not_to be_attached
        expect(ActiveStorage::Blob.exists?(blob.id)).to eq(false)
        expect(receipt).to be_image_purged_by_system
        expect(receipt.image_purge_eligible_at).to be_nil
      end
    end

    it '保持ON、未来eligible、processing、active run、画像なし、purge済みは対象外にする' do
      keep_enabled = purgeable_receipt(keep_image: true)
      future = purgeable_receipt(image_purge_eligible_at: 1.hour.from_now)
      processing = purgeable_receipt(status: 'processing')
      active = purgeable_receipt
      create(:receipt_analysis_run, :running, receipt: active)
      no_image = create(:receipt, :completed, keep_image: false, image_purge_eligible_at: 1.hour.ago)
      purged = purgeable_receipt(
        image_purged_at: 5.minutes.ago,
        image_purged_reason: Receipt::IMAGE_PURGED_REASON_SYSTEM_PURGE
      )

      result = described_class.call(dry_run: false)

      aggregate_failures do
        expect(result).to include(candidate_count: 0, purged_count: 0, skipped_count: 0, failed_count: 0)
        expect(keep_enabled.reload.image).to be_attached
        expect(future.reload.image).to be_attached
        expect(processing.reload.image).to be_attached
        expect(active.reload.image).to be_attached
        expect(no_image.reload.image).not_to be_attached
        expect(purged.reload.image).to be_attached
      end
    end

    it 'limit件数だけ処理する' do
      first = purgeable_receipt(image_purge_eligible_at: 2.hours.ago)
      second = purgeable_receipt(image_purge_eligible_at: 1.hour.ago)

      result = described_class.call(dry_run: false, limit: 1)

      aggregate_failures do
        expect(result).to include(candidate_count: 1, purged_count: 1)
        expect(first.reload.image).not_to be_attached
        expect(second.reload.image).to be_attached
      end
    end

    it '実行後は冪等に再実行できる' do
      receipt = purgeable_receipt

      first_result = described_class.call(dry_run: false)
      second_result = described_class.call(dry_run: false)

      aggregate_failures do
        expect(first_result).to include(candidate_count: 1, purged_count: 1)
        expect(second_result).to include(candidate_count: 0, purged_count: 0, failed_count: 0)
        expect(receipt.reload).to be_image_purged_by_system
      end
    end
  end
end
