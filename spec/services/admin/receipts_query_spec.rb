# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::ReceiptsQuery do
  it 'public_idでreceipt詳細用recordを返し、隔離中receiptも管理者向けに取得する' do
    admin = create(:user, :admin)
    receipt = create(:receipt, :quarantined, quarantined_by: admin, quarantine_reason: 'policy violation')
    receipt.receipt_items.create!(raw_text: 'RAW OCR TEXT', suggested_name: 'AI name', line_total: 100, position_index: 1)
    create(:receipt_adjustment, receipt: receipt, label: '袋代', amount: 5)
    run = create(:receipt_analysis_run, receipt: receipt)
    notification = create(:notification, user: receipt.user, notifiable: receipt, title: '確認してください')

    record = described_class.find(public_id: receipt.public_id)

    aggregate_failures do
      expect(record).to include(
        public_id: receipt.public_id,
        display_id: receipt.display_id,
        moderation_status: 'quarantined'
      )
      expect(record.dig(:moderation, :quarantined)).to be(true)
      expect(record.dig(:moderation, :quarantined_by, :id)).to eq(admin.id)
      expect(record[:counts]).to include(items: 1, adjustments: 1, analysis_runs: 1, notifications: 1)
      expect(record[:recent_items]).to contain_exactly(hash_including(name: 'AI name', line_total: 100))
      expect(record[:recent_items].to_json).not_to include('RAW OCR TEXT')
      expect(record[:recent_adjustments]).to contain_exactly(hash_including(label: '袋代', amount: 5))
      expect(record[:recent_analysis_runs]).to contain_exactly(hash_including(id: run.id, run_key: run.run_key))
      expect(record[:recent_notifications]).to contain_exactly(hash_including(id: notification.id, title: '確認してください'))
      expect(record[:audit_target_uid]).to eq("receipt:#{receipt.public_id}")
    end
  end

  it 'user_idで最新receiptを取得し、通常画面scopeで除外される隔離中も含める' do
    user = create(:user)
    active = create(:receipt, user: user, store_name: '通常')
    quarantined = create(:receipt, :quarantined, user: user, store_name: '隔離')
    create(:receipt, store_name: '他人')

    result = described_class.call(user_id: user.id, limit: 10)

    aggregate_failures do
      expect(result.total_count).to eq(2)
      expect(result.records.map { |record| record[:id] }).to contain_exactly(active.id, quarantined.id)
    end
  end
end
