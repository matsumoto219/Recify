require 'rails_helper'

RSpec.describe Receipt, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  describe '.summary_for' do
    it 'user scopeを適用しstatus別件数を返す' do
      user = create(:user)
      other_user = create(:user, email: 'summary-other@example.com')
      create(:receipt, :completed, user: user)
      create(:receipt, :processing, :with_image, user: user)
      create(:receipt, :review_needed, user: user)
      create(:receipt, :failed, user: user)
      create(:receipt, :failed, user: user)
      create(:receipt, :failed, user: other_user)

      summary = described_class.summary_for(user)

      aggregate_failures do
        expect(summary[:receipts_count]).to eq(5)
        expect(summary[:processing_count]).to eq(1)
        expect(summary[:review_needed_count]).to eq(1)
        expect(summary[:failed_count]).to eq(2)
      end
    end

    it 'completed / review_needed のみを金額KPIに含める' do
      user = create(:user)

      create(:receipt, :completed, user:, total_amount: 1000)
      create(:receipt, :review_needed, user:, total_amount: 2000)
      create(:receipt, :processing, :with_image, user:, total_amount: 3000)
      create(:receipt, :failed, user:, total_amount: 4000)

      summary = described_class.summary_for(user)

      aggregate_failures do
        expect(summary[:current_month_total]).to eq(3000)
        expect(summary[:overall_total]).to eq(3000)
      end
    end

    it '今月/先月の金額差分を対象statusだけで計算する' do
      user = create(:user)
      current_month = Time.zone.local(2026, 5, 16, 12, 0, 0)
      previous_month = Time.zone.local(2026, 4, 16, 12, 0, 0)

      travel_to(current_month) do
        create(:receipt, :completed, user:, total_amount: 2000, purchased_at: current_month)
        create(:receipt, :review_needed, user:, total_amount: 1000, purchased_at: current_month)
        create(:receipt, :failed, user:, total_amount: 9000, purchased_at: current_month)
        create(:receipt, :completed, user:, total_amount: 1500, purchased_at: previous_month)

        summary = described_class.summary_for(user)

        aggregate_failures do
          expect(summary[:current_month_total]).to eq(3000)
          expect(summary[:previous_month_total]).to eq(1500)
          expect(summary[:monthly_change_label]).to eq('先月比 +100%')
          expect(summary[:monthly_change_icon]).to eq('trending_up')
        end
      end
    end
  end

  describe '.category_summary_for' do
    def create_item(receipt, category:, line_total:, name: '商品')
      receipt.receipt_items.create!(
        raw_text: name,
        confirmed_name: name,
        category: category,
        quantity: 1,
        price: line_total,
        line_total: line_total,
        position_index: receipt.receipt_items.count + 1
      )
    end

    it 'completed / review_needed の明細だけカテゴリ別に金額と件数を集計する' do
      user = create(:user)
      completed = create(:receipt, :completed, user:)
      review_needed = create(:receipt, :review_needed, user:)
      processing = create(:receipt, :processing, :with_image, user:)
      failed = create(:receipt, :failed, user:)

      create_item(completed, category: 'food', line_total: 500)
      create_item(completed, category: 'food', line_total: 700)
      create_item(review_needed, category: 'drink', line_total: 300)
      create_item(processing, category: 'food', line_total: 9_999)
      create_item(failed, category: 'drink', line_total: 9_999)

      summary = described_class.category_summary_for(user)

      aggregate_failures do
        expect(summary).to include(
          hash_including(category: 'food', label: '食品', total_amount: 1200, item_count: 2),
          hash_including(category: 'drink', label: '飲料', total_amount: 300, item_count: 1)
        )
        expect(summary.map { |entry| entry[:total_amount] }.sum).to eq(1500)
      end
    end

    it 'user scopeを適用する' do
      user = create(:user)
      other_user = create(:user)
      receipt = create(:receipt, :completed, user:)
      other_receipt = create(:receipt, :completed, user: other_user)

      create_item(receipt, category: 'food', line_total: 500)
      create_item(other_receipt, category: 'food', line_total: 10_000)

      summary = described_class.category_summary_for(user)

      expect(summary).to contain_exactly(hash_including(category: 'food', total_amount: 500, item_count: 1))
    end

    it 'nil / blank category は uncategorized として扱い、other は other のまま扱う' do
      user = create(:user)
      receipt = create(:receipt, :completed, user:)

      create_item(receipt, category: nil, line_total: 100)
      create_item(receipt, category: '', line_total: 200)
      create_item(receipt, category: 'other', line_total: 300)

      summary = described_class.category_summary_for(user)

      aggregate_failures do
        expect(summary).to include(hash_including(category: 'uncategorized', label: '未分類', total_amount: 300, item_count: 2))
        expect(summary).to include(hash_including(category: 'other', label: 'その他', total_amount: 300, item_count: 1))
      end
    end

    it '検索scope内で集計できる' do
      user = create(:user)
      coffee_receipt = create(:receipt, :completed, user:, store_name: 'コーヒーストア')
      grocery_receipt = create(:receipt, :completed, user:, store_name: '食品ストア')

      create_item(coffee_receipt, category: 'drink', line_total: 450, name: 'コーヒー')
      create_item(grocery_receipt, category: 'food', line_total: 800, name: 'パン')

      scope = user.receipts.search('コーヒー')
      summary = described_class.category_summary_for(user, scope:)

      expect(summary).to contain_exactly(hash_including(category: 'drink', total_amount: 450, item_count: 1))
    end
  end

  describe '.search' do
    it 'subquery用途のmatching idsには既存orderを持ち込まない' do
      sql = described_class.order(created_at: :desc).search('コーヒー').to_sql

      aggregate_failures do
        expect(sql).to include('ORDER BY "receipts"."created_at" DESC')
        expect(sql.scan(/ORDER BY/).size).to eq(1)
      end
    end
  end

  describe 'query indexes' do
    it 'receipts index / KPI / status count 用の複合indexを持つ' do
      indexes = ActiveRecord::Base.connection.indexes(:receipts)

      aggregate_failures do
        expect(indexes).to include(have_attributes(columns: %w[user_id created_at]))
        expect(indexes).to include(have_attributes(columns: %w[user_id status]))
        expect(indexes).to include(have_attributes(columns: %w[user_id status purchased_at]))
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
        [ user, :receipts, :index_first_page ],
        target: "receipts-list-grid",
        partial: "shared/receipts/receipt_card",
        locals: { receipt: receipt }
      )
      expect(receipt).to receive(:broadcast_remove_to).with(
        [ user, :receipts, :index_first_page ],
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

    it 'processingからcompletedになった時に永続通知を作成する' do
      receipt = create(:receipt, :processing, :with_image, user: user, store_name: '完了ストア')

      expect {
        receipt.update!(status: 'completed')
      }.to change(user.notifications, :count).by(1)

      notification = user.notifications.last

      aggregate_failures do
        expect(notification.kind).to eq('receipt_completed')
        expect(notification.notifiable).to eq(receipt)
        expect(notification.action_path).to eq("/receipts/#{receipt.id}")
        expect(notification.title).to include('完了')
      end
    end

    it 'uploadedからreview_neededになった時に永続通知を作成する' do
      receipt = create(:receipt, status: 'uploaded', user: user)

      expect {
        receipt.update!(status: 'review_needed')
      }.to change(user.notifications, :count).by(1)

      expect(user.notifications.last.kind).to eq('receipt_review_needed')
    end

    it 'processingからfailedになった時に永続通知を作成する' do
      receipt = create(:receipt, :processing, :with_image, user: user)

      expect {
        receipt.update!(status: 'failed', processing_error_code: 'ocr_api_error')
      }.to change(user.notifications, :count).by(1)

      notification = user.notifications.last

      aggregate_failures do
        expect(notification.kind).to eq('receipt_failed')
        expect(notification.body).to be_present
      end
    end

    it 'failedからcompletedに手動復旧しても永続通知を作成しない' do
      receipt = create(:receipt, :failed, user: user)

      expect {
        receipt.update!(status: 'completed', processing_error_code: nil)
      }.not_to change(user.notifications, :count)
    end

    it 'status変更なしでは永続通知を作成しない' do
      receipt = create(:receipt, :completed, user: user)

      expect {
        receipt.update!(store_name: '更新後ストア')
      }.not_to change(user.notifications, :count)
    end

    it 'completed/review_needed/failed のprocessing flashをshared/flashでbroadcastする' do
      cases = [
        {
          status: "completed",
          processing_error_code: nil,
          flash_type: :notice,
          message: "レシート解析が完了しました"
        },
        {
          status: "review_needed",
          processing_error_code: nil,
          flash_type: :caution,
          message: "レシート解析が完了しました。内容を確認してください"
        },
        {
          status: "failed",
          processing_error_code: "ocr_api_error",
          flash_type: :alert,
          message: I18n.t("receipts.processing_errors.ocr_error")
        }
      ]

      cases.each do |entry|
        receipt = build_stubbed(
          :receipt,
          user: user,
          status: entry[:status],
          processing_error_code: entry[:processing_error_code]
        )

        expect(receipt).to receive(:broadcast_replace_later_to).with(
          [ user, :receipts ],
          target: "flash",
          partial: "shared/flash",
          locals: {
            flash_messages: {
              entry[:flash_type] => [ entry[:message] ]
            }
          }
        )

        receipt.send(:broadcast_processing_flash)
      end
    end

    it 'total_amount更新時にsummary cardsをreplaceする' do
      receipt = create(:receipt, :completed, user: user)

      expect(receipt).to receive(:broadcast_summary_cards_update).and_call_original

      receipt.update!(total_amount: 2_000)
    end

    it 'purchased_at更新時にsummary cardsをreplaceする' do
      receipt = create(:receipt, :completed, user: user)

      expect(receipt).to receive(:broadcast_summary_cards_update).and_call_original

      receipt.update!(purchased_at: 1.month.ago)
    end

    it 'destroy時にsummary cardsをreplaceする' do
      receipt = create(:receipt, :completed, user: user)

      expect(receipt).to receive(:broadcast_summary_cards_update).and_call_original

      receipt.destroy!
    end
  end
end
