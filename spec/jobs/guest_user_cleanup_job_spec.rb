require 'rails_helper'

RSpec.describe GuestUserCleanupJob, type: :job do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test

    travel_to(Time.zone.parse('2026-05-22 10:00:00')) do
      clear_enqueued_jobs
      clear_performed_jobs
      example.run
      clear_enqueued_jobs
      clear_performed_jobs
    end
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  describe '#perform' do
    it '7日以上前にログインしたconfirmed guestを削除する' do
      old_guest = create_old_guest

      result = described_class.perform_now

      aggregate_failures do
        expect(User.exists?(old_guest.id)).to be(false)
        expect(result).to eq(deleted_count: 1, failed_count: 0)
      end
    end

    it '7日未満のguestは削除しない' do
      recent_guest = create(:user, guest: true, last_sign_in_at: 6.days.ago)

      result = described_class.perform_now

      aggregate_failures do
        expect(User.exists?(recent_guest.id)).to be(true)
        expect(result).to eq(deleted_count: 0, failed_count: 0)
      end
    end

    it '通常ユーザーは削除しない' do
      regular_user = create(:user, guest: false, last_sign_in_at: 8.days.ago)

      result = described_class.perform_now

      aggregate_failures do
        expect(User.exists?(regular_user.id)).to be(true)
        expect(result).to eq(deleted_count: 0, failed_count: 0)
      end
    end

    it 'unconfirmed guestは削除しない' do
      unconfirmed_guest = create(:user, :unconfirmed, guest: true, last_sign_in_at: 8.days.ago)

      result = described_class.perform_now

      aggregate_failures do
        expect(User.exists?(unconfirmed_guest.id)).to be(true)
        expect(result).to eq(deleted_count: 0, failed_count: 0)
      end
    end

    it 'last_sign_in_atがないguestはupdated_at fallbackで判定する' do
      old_guest = create(:user, guest: true, last_sign_in_at: nil)
      recent_guest = create(:user, guest: true, last_sign_in_at: nil)
      old_guest.update_columns(updated_at: 8.days.ago)
      recent_guest.update_columns(updated_at: 6.days.ago)

      result = described_class.perform_now

      aggregate_failures do
        expect(User.exists?(old_guest.id)).to be(false)
        expect(User.exists?(recent_guest.id)).to be(true)
        expect(result).to eq(deleted_count: 1, failed_count: 0)
      end
    end

    it 'receiptsと関連明細を削除する' do
      guest = create_old_guest
      receipt = create(:receipt, user: guest)
      item = receipt.receipt_items.create!(receipt_item_attributes)
      payment = receipt.receipt_payments.create!(method: 'cash', amount: 1000)
      tax_detail = receipt.receipt_tax_details.create!(description: '10%', amount: 91, rate: 0.1, net_amount: 909)

      described_class.perform_now

      aggregate_failures do
        expect(Receipt.exists?(receipt.id)).to be(false)
        expect(ReceiptItem.exists?(item.id)).to be(false)
        expect(ReceiptPayment.exists?(payment.id)).to be(false)
        expect(ReceiptTaxDetail.exists?(tax_detail.id)).to be(false)
      end
    end

    it 'notificationsを削除する' do
      guest = create_old_guest
      receipt = create(:receipt, user: guest)
      user_notification = create(:notification, user: guest)
      receipt_notification = create(
        :notification,
        user: guest,
        kind: 'receipt_review_needed',
        notifiable: receipt,
        action_path: "/receipts/#{receipt.public_id}"
      )

      described_class.perform_now

      aggregate_failures do
        expect(Notification.exists?(user_notification.id)).to be(false)
        expect(Notification.exists?(receipt_notification.id)).to be(false)
      end
    end

    it 'avatarとreceipt image attachmentを削除しActiveStorage::PurgeJobをenqueueする' do
      guest = create_old_guest
      guest.avatar.attach(
        io: File.open(Rails.root.join('spec/fixtures/files/receipt_sample.jpg')),
        filename: 'avatar.jpg',
        content_type: 'image/jpeg'
      )
      receipt = create(:receipt, :with_image, user: guest)
      attachment_ids = [ guest.avatar.attachment.id, receipt.image.attachment.id ]

      clear_enqueued_jobs

      described_class.perform_now

      aggregate_failures do
        expect(ActiveStorage::Attachment.where(id: attachment_ids)).to be_empty
        expect(enqueued_jobs.count { |job| job[:job] == ActiveStorage::PurgeJob }).to eq(2)
        expect(enqueued_jobs.none? { |job| job[:job] == Turbo::Streams::ActionBroadcastJob }).to be(true)
      end
    end

    it 'max_recordsを上限にbatch処理する' do
      create_list(:user, 101, guest: true, last_sign_in_at: 8.days.ago)

      result = described_class.perform_now(batch_size: 10, max_records: 100)

      aggregate_failures do
        expect(result).to eq(deleted_count: 100, failed_count: 0)
        expect(User.guest_cleanup_candidates.count).to eq(1)
      end
    end

    it '再実行しても壊れない' do
      create_old_guest

      first_result = described_class.perform_now
      second_result = described_class.perform_now

      aggregate_failures do
        expect(first_result).to eq(deleted_count: 1, failed_count: 0)
        expect(second_result).to eq(deleted_count: 0, failed_count: 0)
      end
    end

    it '1件失敗しても残りを続行し失敗件数をログに残す' do
      failed_guest = create_old_guest
      deleted_guest = create_old_guest
      allow(Rails.logger).to receive(:error)
      allow_any_instance_of(User).to receive(:destroy!).and_wrap_original do |method, *args|
        raise StandardError, 'cleanup failed' if method.receiver.id == failed_guest.id

        method.call(*args)
      end

      result = described_class.perform_now

      aggregate_failures do
        expect(User.exists?(failed_guest.id)).to be(true)
        expect(User.exists?(deleted_guest.id)).to be(false)
        expect(result).to eq(deleted_count: 1, failed_count: 1)
        expect(Rails.logger).to have_received(:error).with(include("[GuestUserCleanupJob] failed user_id=#{failed_guest.id}"))
      end
    end
  end

  def create_old_guest
    create(:user, guest: true, last_sign_in_at: 8.days.ago)
  end

  def receipt_item_attributes
    {
      raw_text: '商品A',
      suggested_name: '商品A',
      confirmed_name: '商品A',
      category: 'food',
      price: 1000,
      quantity: 1,
      line_total: 1000
    }
  end
end
