require 'rails_helper'

RSpec.describe ReceiptAnalysisRunRetentionCleanupJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-23 10:00:00')) { example.run }
  end

  it 'dry_run trueをdefaultにしてReceiptAnalysisRuns親入口を呼ぶ' do
    result = {
      dry_run: true,
      expired_count: 0,
      deleted_count: 0
    }
    allow(ReceiptAnalysisRuns).to receive(:cleanup_expired).and_return(result)
    allow(Rails.logger).to receive(:info)

    expect { expect(described_class.perform_now).to eq(result) }
      .to change(AuditLog, :count).by(1)

    audit_log = AuditLog.last

    aggregate_failures do
      expect(ReceiptAnalysisRuns).to have_received(:cleanup_expired).with(
        cutoff: Time.current,
        limit: 1000,
        dry_run: true
      )
      expect(Rails.logger).to have_received(:info).with(include('[ReceiptAnalysisRunRetentionCleanupJob] completed dry_run=true'))
      expect(audit_log).to have_attributes(
        actor_kind: 'system',
        action: 'receipt_analysis_runs.cleanup_expired.dry_run',
        outcome: 'succeeded'
      )
      expect(audit_log.metadata).to include(
        'dry_run' => true,
        'limit' => 1000,
        'expired_count' => 0,
        'deleted_count' => 0,
        'sample_run_keys' => []
      )
    end
  end

  it '指定した引数で親入口を呼ぶ' do
    cutoff = 1.day.ago
    result = {
      dry_run: false,
      expired_count: 2,
      deleted_count: 2
    }
    allow(ReceiptAnalysisRuns).to receive(:cleanup_expired).and_return(result)

    expect(described_class.perform_now(cutoff: cutoff, limit: 10, dry_run: false)).to eq(result)

    expect(ReceiptAnalysisRuns).to have_received(:cleanup_expired).with(
      cutoff: cutoff,
      limit: 10,
      dry_run: false
    )
  end

  it 'dry_run結果をsystem auditとして記録しsample_run_keysを20件に制限する' do
    records = Array.new(25) do |index|
      {
        run_key: "expired-run-#{index}",
        raw_response: 'RAW OCR RESPONSE',
        prompt: 'FULL PROMPT',
        secret_token: 'SECRET'
      }
    end
    result = {
      dry_run: true,
      cutoff: Time.current,
      limit: 1000,
      expired_count: 25,
      deleted_count: 0,
      records: records
    }
    allow(ReceiptAnalysisRuns).to receive(:cleanup_expired).and_return(result)

    described_class.perform_now

    audit_log = AuditLog.last
    metadata_json = audit_log.metadata.to_json

    aggregate_failures do
      expect(audit_log).to have_attributes(
        actor_kind: 'system',
        action: 'receipt_analysis_runs.cleanup_expired.dry_run',
        outcome: 'succeeded'
      )
      expect(audit_log.metadata).to include(
        'dry_run' => true,
        'cutoff' => Time.current.iso8601,
        'limit' => 1000,
        'expired_count' => 25,
        'deleted_count' => 0
      )
      expect(audit_log.metadata['sample_run_keys']).to eq(Array.new(20) { |index| "expired-run-#{index}" })
      expect(metadata_json).not_to include('RAW OCR RESPONSE')
      expect(metadata_json).not_to include('FULL PROMPT')
      expect(metadata_json).not_to include('SECRET')
    end
  end

  it 'cleanup失敗時にfailed auditを残して例外を再raiseする' do
    error = StandardError.new('boom')
    allow(ReceiptAnalysisRuns).to receive(:cleanup_expired).and_raise(error)

    expect do
      described_class.perform_now
    end.to raise_error(StandardError, 'boom')
      .and change(AuditLog, :count).by(1)

    audit_log = AuditLog.last

    aggregate_failures do
      expect(audit_log).to have_attributes(
        actor_kind: 'system',
        action: 'receipt_analysis_runs.cleanup_expired.dry_run',
        outcome: 'failed',
        error_code: 'cleanup_failed'
      )
      expect(audit_log.metadata).to include(
        'dry_run' => true,
        'limit' => 1000,
        'error_class' => 'StandardError',
        'sample_run_keys' => []
      )
      expect(audit_log.metadata).not_to have_key('error_message')
    end
  end
end
