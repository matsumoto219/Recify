require 'rails_helper'

RSpec.describe ReceiptAnalysisRun, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  def insert_run!(receipt:, status:, run_key: SecureRandom.uuid)
    now = Time.current

    described_class.insert_all!([
      {
        receipt_id: receipt.id,
        run_key: run_key,
        source: 'upload',
        stage: 'queued',
        status: status,
        attempt_number: 1,
        ai_fallback_used: false,
        ocr_summary: {},
        ocr_result_snapshot: {},
        ai_input_snapshot: {},
        ai_result_summary: {},
        ai_normalized_result_snapshot: {},
        final_result_summary: {},
        metadata: {},
        expires_at: 30.days.from_now,
        created_at: now,
        updated_at: now
      }
    ])
  end

  describe 'associations' do
    it 'receipt / requested_by_user / parent_run と関連する' do
      user = create(:user)
      receipt = create(:receipt, user:)
      parent_run = create(:receipt_analysis_run, :succeeded, receipt:)
      run = create(:receipt_analysis_run, :admin_retry, receipt:, parent_run:)

      aggregate_failures do
        expect(run.receipt).to eq(receipt)
        expect(run.requested_by_user).to be_present
        expect(run.parent_run).to eq(parent_run)
        expect(parent_run.child_runs).to include(run)
        expect(run.requested_by_user.requested_receipt_analysis_runs).to include(run)
        expect(receipt.receipt_analysis_runs).to include(run)
      end
    end
  end

  describe 'defaults' do
    around do |example|
      travel_to(Time.zone.parse('2026-05-23 10:00:00')) { example.run }
    end

    it 'run_keyを自動生成する' do
      run = create(:receipt_analysis_run)

      expect(run.run_key).to match(/\A[0-9a-f-]{36}\z/)
    end

    it 'jsonb snapshots は空Hashをdefaultにする' do
      run = described_class.create!(
        receipt: create(:receipt),
        source: 'upload',
        stage: 'queued',
        status: 'queued'
      )

      aggregate_failures do
        expect(run.ocr_summary).to eq({})
        expect(run.ocr_result_snapshot).to eq({})
        expect(run.ai_input_snapshot).to eq({})
        expect(run.ai_result_summary).to eq({})
        expect(run.ai_normalized_result_snapshot).to eq({})
        expect(run.final_result_summary).to eq({})
        expect(run.metadata).to eq({})
      end
    end

    it 'normalized snapshots を保存して読み出せる' do
      run = create(
        :receipt_analysis_run,
        ocr_result_snapshot: {
          candidates: {
            store_name: 'テストストア',
            items: [ { raw_text: 'コーヒー', line_total: 180 } ]
          }
        },
        ai_normalized_result_snapshot: {
          success: true,
          receipt_attributes: { payment_method: 'cash' },
          receipt_items_attributes: [ { index: 0, category: 'drink' } ]
        }
      )

      aggregate_failures do
        expect(run.reload.ocr_result_snapshot.dig('candidates', 'store_name')).to eq('テストストア')
        expect(run.ocr_result_snapshot.dig('candidates', 'items', 0, 'line_total')).to eq(180)
        expect(run.ai_normalized_result_snapshot).to include('success' => true)
        expect(run.ai_normalized_result_snapshot.dig('receipt_attributes', 'payment_method')).to eq('cash')
      end
    end

    it 'status/sourceに応じたexpires_atを設定する' do
      succeeded = create(:receipt_analysis_run, :succeeded)
      failed = create(:receipt_analysis_run, :failed)
      superseded = create(:receipt_analysis_run, :superseded)
      skipped = create(:receipt_analysis_run, :skipped)
      canceled = create(:receipt_analysis_run, status: 'canceled')
      admin_retry = create(:receipt_analysis_run, :admin_retry, :succeeded)

      aggregate_failures do
        expect(succeeded.expires_at).to eq(30.days.from_now)
        expect(failed.expires_at).to eq(90.days.from_now)
        expect(superseded.expires_at).to eq(14.days.from_now)
        expect(skipped.expires_at).to eq(14.days.from_now)
        expect(canceled.expires_at).to eq(14.days.from_now)
        expect(admin_retry.expires_at).to eq(90.days.from_now)
      end
    end

    it 'receipt_statusがreview_needed / failedの場合は長めの保持期間にする' do
      aggregate_failures do
        expect(described_class.retention_period_for(status: 'succeeded', source: 'upload', receipt_status: 'completed')).to eq(30.days)
        expect(described_class.retention_period_for(status: 'succeeded', source: 'upload', receipt_status: 'review_needed')).to eq(90.days)
        expect(described_class.retention_period_for(status: 'succeeded', source: 'upload', receipt_status: 'failed')).to eq(90.days)
        expect(described_class.retention_period_for(status: 'succeeded', source: 'upload', receipt_status: nil)).to eq(30.days)
      end
    end

    it 'SystemSettingsの保持期間でexpires_atを設定する' do
      create(:system_setting, key: 'retention.analysis_runs_short_days', value: SystemSettings.stored_value(7))
      create(:system_setting, key: 'retention.analysis_runs_default_days', value: SystemSettings.stored_value(45))
      create(:system_setting, key: 'retention.analysis_runs_failed_days', value: SystemSettings.stored_value(120))

      succeeded = create(:receipt_analysis_run, :succeeded)
      failed = create(:receipt_analysis_run, :failed)
      superseded = create(:receipt_analysis_run, :superseded)
      admin_retry = create(:receipt_analysis_run, :admin_retry, :succeeded)

      aggregate_failures do
        expect(described_class.short_retention_period).to eq(7.days)
        expect(described_class.default_retention_period).to eq(45.days)
        expect(described_class.long_retention_period).to eq(120.days)
        expect(succeeded.expires_at).to eq(45.days.from_now)
        expect(failed.expires_at).to eq(120.days.from_now)
        expect(superseded.expires_at).to eq(7.days.from_now)
        expect(admin_retry.expires_at).to eq(120.days.from_now)
      end
    end

    it '明示されたexpires_atは上書きしない' do
      expires_at = 7.days.from_now
      run = create(:receipt_analysis_run, expires_at:)

      expect(run.expires_at).to eq(expires_at)
    end
  end

  describe 'validations' do
    it 'stage / status / source の許可値だけを受け付ける' do
      run = build(:receipt_analysis_run, stage: 'unknown_stage', status: 'unknown_status', source: 'unknown_source')

      expect(run).not_to be_valid

      aggregate_failures do
        expect(run.errors[:stage]).to be_present
        expect(run.errors[:status]).to be_present
        expect(run.errors[:source]).to be_present
      end
    end

    it 'attempt_number は1以上のintegerにする' do
      run = build(:receipt_analysis_run, attempt_number: 0)

      expect(run).not_to be_valid
      expect(run.errors[:attempt_number]).to be_present
    end

    it 'latencyは0以上のintegerにする' do
      run = build(:receipt_analysis_run, ocr_latency_ms: -1, ai_latency_ms: 1.5, total_latency_ms: -10)

      expect(run).not_to be_valid

      aggregate_failures do
        expect(run.errors[:ocr_latency_ms]).to be_present
        expect(run.errors[:ai_latency_ms]).to be_present
        expect(run.errors[:total_latency_ms]).to be_present
      end
    end

    it '同一receiptのactive runは1件だけにする' do
      receipt = create(:receipt)
      create(:receipt_analysis_run, receipt:, status: 'queued')

      duplicate = build(:receipt_analysis_run, receipt:, status: 'running')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:receipt]).to be_present
    end

    it 'succeeded / failed / superseded はactive run制約に引っかからない' do
      receipt = create(:receipt)
      create(:receipt_analysis_run, :succeeded, receipt:)
      create(:receipt_analysis_run, :failed, receipt:)
      create(:receipt_analysis_run, :superseded, receipt:)

      active_run = build(:receipt_analysis_run, receipt:, status: 'queued')

      expect(active_run).to be_valid
    end
  end

  describe 'database constraints' do
    it 'run_keyはDB制約でも一意にする' do
      run_key = SecureRandom.uuid
      create(:receipt_analysis_run, run_key:)

      expect do
        create(:receipt_analysis_run, run_key:)
      end.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'partial unique indexで同一receiptのactive run重複を防ぐ' do
      receipt = create(:receipt)
      insert_run!(receipt:, status: 'queued')

      expect do
        insert_run!(receipt:, status: 'running')
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it '非active statusはpartial unique index対象外にする' do
      receipt = create(:receipt)
      insert_run!(receipt:, status: 'succeeded')
      insert_run!(receipt:, status: 'failed')
      insert_run!(receipt:, status: 'superseded')

      expect(described_class.where(receipt:).count).to eq(3)
    end

    it 'migrationで必要なindexを持つ' do
      indexes = ActiveRecord::Base.connection.indexes(:receipt_analysis_runs)

      aggregate_failures do
        run_key_index = indexes.find { |index| index.name == 'index_receipt_analysis_runs_on_run_key' }
        expect(run_key_index).to be_present
        expect(run_key_index.unique).to be(true)
        expect(indexes.find { |index| index.columns == %w[receipt_id created_at] }).to be_present
        expect(indexes.find { |index| index.columns == %w[status stage] }).to be_present
        expect(indexes.find { |index| index.columns == %w[expires_at] }).to be_present

        active_index = indexes.find { |index| index.name == 'index_receipt_analysis_runs_one_active_per_receipt' }
        expect(active_index).to be_present
        expect(active_index.unique).to be(true)
        expect(active_index.where).to include("status")
        expect(active_index.where).to include("queued")
        expect(active_index.where).to include("running")
      end
    end

    it 'normalized snapshot columns はnull falseかつ空Hash defaultにする' do
      columns = ActiveRecord::Base.connection.columns(:receipt_analysis_runs).index_by(&:name)

      aggregate_failures do
        expect(columns.fetch('ocr_result_snapshot').null).to eq(false)
        expect(columns.fetch('ocr_result_snapshot').default).to eq('{}')
        expect(columns.fetch('ai_normalized_result_snapshot').null).to eq(false)
        expect(columns.fetch('ai_normalized_result_snapshot').default).to eq('{}')
      end
    end
  end

  describe 'raw data policy' do
    it 'raw全文や外部API生レスポンス用の専用カラムを持たない' do
      forbidden_columns = %w[
        ocr_raw_text
        azure_raw_response
        ai_raw_response
        prompt
        prompt_text
        response_body
      ]

      expect(described_class.column_names & forbidden_columns).to be_empty
    end
  end
end
