require 'rails_helper'

RSpec.describe Receipt, type: :model do
  describe '.summary_for' do
    it 'failed_countを返す' do
      user = create(:user)
      create(:receipt, :completed, user: user)
      create(:receipt, :processing, :with_image, user: user)
      create(:receipt, :review_needed, user: user)
      create(:receipt, :failed, user: user)
      create(:receipt, :failed, user: user)

      summary = described_class.summary_for(user)

      aggregate_failures do
        expect(summary[:processing_count]).to eq(1)
        expect(summary[:review_needed_count]).to eq(1)
        expect(summary[:failed_count]).to eq(2)
      end
    end
  end

  describe 'broadcasts' do
    let(:user) { create(:user) }

    it 'processing receipt作成時だけprepend callbackを実行する' do
      expect_any_instance_of(described_class).to receive(:broadcast_receipt_card_prepend).once

      create(:receipt, :processing, :with_image, user: user)
      create(:receipt, :completed, user: user)
    end

    it 'processing作成時にreceipts-list-gridへカードをprependする' do
      receipt = build_stubbed(:receipt, :processing, user: user)

      expect(receipt).to receive(:broadcast_prepend_later_to).with(
        [ user, :receipts ],
        target: "receipts-list-grid",
        partial: "shared/receipts/receipt_card",
        locals: { receipt: receipt }
      )
      expect(receipt).to receive(:broadcast_remove_to).with(
        [ user, :receipts ],
        target: "receipts-empty-state"
      )

      receipt.send(:broadcast_receipt_card_prepend)
    end

    it 'create時にもsummary cardsをreplaceするcallbackを持つ' do
      create_callback_filters = described_class.__send__(:get_callbacks, :commit).select do |callback|
        callback.kind == :after
      end.map(&:filter)

      expect(create_callback_filters).to include(:broadcast_created_summary_cards_update)
    end

    it 'summary broadcast localsにfailed_countを含める' do
      receipt = build_stubbed(:receipt, user: user)
      summary = described_class.summary_for(user)

      expect(receipt).to receive(:broadcast_replace_later_to).with(
        [ user, :receipts ],
        target: "receipts_summary",
        partial: "shared/receipts/summary_cards",
        locals: hash_including(failed_count: summary[:failed_count])
      )

      receipt.send(:broadcast_summary_cards_update)
    end

    it 'status更新時の既存broadcastを維持する' do
      receipt = create(:receipt, :processing, :with_image, user: user)

      expect(receipt).to receive(:broadcast_receipt_card_update).and_call_original
      expect(receipt).to receive(:broadcast_summary_cards_update).and_call_original
      expect(receipt).to receive(:broadcast_processing_flash).and_call_original

      receipt.update!(status: "completed")
    end
  end
end
