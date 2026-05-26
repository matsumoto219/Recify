require 'rails_helper'

RSpec.describe Admin::AuditLogsQuery do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-26 12:00:00')) { example.run }
  end

  describe '.call' do
    it 'latest順で管理画面用recordを返す' do
      older = create(:audit_log, action: 'receipt_analysis.ai_retry', created_at: 2.hours.ago)
      newer = create(:audit_log, :failed, action: 'receipt_analysis.finalize_retry', created_at: 1.hour.ago)

      result = Admin.audit_logs

      aggregate_failures do
        expect(result.records.map { |record| record[:audit_log] }).to eq([ newer, older ])
        expect(result.records.first).to include(
          audit_log: newer,
          id: newer.id,
          action: 'receipt_analysis.finalize_retry',
          outcome: 'failed',
          error_code: 'operation_failed',
          target_uid: 'rcpt_test'
        )
        expect(result.limit).to eq(50)
        expect(result.offset).to eq(0)
        expect(result.total_count).to eq(2)
      end
    end

    it 'id / actor_user_id / actor_kind / action / outcomeで絞り込める' do
      actor = create(:user)
      target = create(:audit_log, actor_user: actor, actor_kind: 'admin', action: 'receipt_analysis.full_reanalyze', outcome: 'succeeded')
      system_log = create(:audit_log, :system, action: 'receipt_analysis.stale_cleanup', outcome: 'succeeded')
      failed_log = create(:audit_log, :failed, action: 'receipt_analysis.ai_retry')

      aggregate_failures do
        expect(described_class.call(id: target.id).records.map { |record| record[:audit_log] }).to eq([ target ])
        expect(described_class.call(actor_user_id: actor.id).records.map { |record| record[:audit_log] }).to eq([ target ])
        expect(described_class.call(actor_kind: 'system').records.map { |record| record[:audit_log] }).to eq([ system_log ])
        expect(described_class.call(action: 'receipt_analysis.ai_retry').records.map { |record| record[:audit_log] }).to eq([ failed_log ])
        expect(described_class.call(outcome: 'failed').records.map { |record| record[:audit_log] }).to eq([ failed_log ])
      end
    end

    it 'target_uid / request_id / error_codeで絞り込める' do
      target = create(:audit_log, target_uid: 'rcpt_target', request_id: 'req-target', error_code: 'retry_failed')
      create(:audit_log, target_uid: 'rcpt_other', request_id: 'req-other', error_code: nil)

      aggregate_failures do
        expect(described_class.call(target_uid: 'rcpt_target').records.map { |record| record[:audit_log] }).to eq([ target ])
        expect(described_class.call(request_id: 'req-target').records.map { |record| record[:audit_log] }).to eq([ target ])
        expect(described_class.call(error_code: 'retry_failed').records.map { |record| record[:audit_log] }).to eq([ target ])
      end
    end

    it 'created_from / created_toで絞り込める' do
      older = create(:audit_log, created_at: 3.days.ago)
      middle = create(:audit_log, created_at: 1.day.ago)
      newer = create(:audit_log, created_at: 1.hour.ago)

      aggregate_failures do
        expect(described_class.call(created_from: 2.days.ago.iso8601).records.map { |record| record[:audit_log] }).to contain_exactly(middle, newer)
        expect(described_class.call(created_to: 12.hours.ago.iso8601).records.map { |record| record[:audit_log] }).to contain_exactly(older, middle)
      end
    end

    it 'limit上限とoffsetを適用する' do
      logs = Array.new(3) { |index| create(:audit_log, created_at: index.minutes.ago) }

      result = described_class.call(limit: 500, offset: 1)

      aggregate_failures do
        expect(result.limit).to eq(100)
        expect(result.offset).to eq(1)
        expect(result.total_count).to eq(3)
        expect(result.records.map { |record| record[:audit_log] }).to eq(logs.sort_by(&:created_at).reverse.drop(1))
      end
    end

    it 'actor_userをeager loadする' do
      allow(AuditLog).to receive(:includes).and_call_original

      described_class.call

      expect(AuditLog).to have_received(:includes).with(:actor_user)
    end

    it 'metadata / before_state / after_stateを表示時にも再sanitizeする' do
      log = create(
        :audit_log,
        metadata: {
          safe: 'visible',
          raw_text: 'RAW OCR',
          prompt: 'FULL PROMPT',
          nested: {
            secret_token: 'SECRET',
            kept: 'ok'
          }
        },
        before_state: {
          password: 'PASSWORD',
          status: 'failed'
        },
        after_state: {
          response_body: 'RAW AI',
          status: 'processing'
        }
      )

      record = described_class.call(id: log.id).records.first
      json = JSON.generate(record.slice(:metadata, :before_state, :after_state))

      aggregate_failures do
        expect(json).to include('visible', 'ok', 'failed', 'processing')
        expect(json).not_to include('RAW OCR')
        expect(json).not_to include('FULL PROMPT')
        expect(json).not_to include('SECRET')
        expect(json).not_to include('PASSWORD')
        expect(json).not_to include('RAW AI')
      end
    end
  end
end
