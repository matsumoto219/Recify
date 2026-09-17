require 'rails_helper'
require_relative '../../support/run_amount_inspector_helpers'

RSpec.describe Admin::ReceiptAnalysisRunsQuery do
  include RunAmountInspectorHelpers

  it '一覧専用projectionはSQLでrun診断を除去しread-only recordを返す' do
    run = create(:receipt_analysis_run, :succeeded,
      final_result_summary: { schema_version: 1, receipt_status: 'review_needed', amount_calculation_run_snapshot: run_amount_snapshot })
    queries = []
    subscriber = ->(_name, _started, _finished, _id, payload) { queries << payload[:sql] }
    result = nil
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      result = described_class.call(run_key: run.run_key, summary_only: true, receipt_status: 'review_needed')
    end
    record = result.records.fetch(0)

    aggregate_failures do
      expect(result.total_count).to eq(1)
      expect(record[:run]).to be_readonly
      expect(record[:run].final_result_summary).to eq('schema_version' => 1, 'receipt_status' => 'review_needed')
      expect(record).not_to have_key(:amount_calculation_run_snapshot)
      expect(queries.grep(/SELECT.*FROM "receipt_analysis_runs"/).join).to include("final_result_summary\" - 'amount_calculation_run_snapshot'")
      expect(run.reload.final_result_summary).to have_key('amount_calculation_run_snapshot')
    end
  end

  it '詳細は診断を取得し、汎用JSON表示からは常に分離する' do
    snapshot = run_amount_snapshot
    run = create(:receipt_analysis_run, :succeeded, final_result_summary: { amount_calculation_run_snapshot: snapshot })

    record = described_class.call(run_key: run.run_key, include_amount_profile: true).records.fetch(0)
    retry_record = described_class.call(run_key: run.run_key, include_retry_options: true).records.fetch(0)

    aggregate_failures do
      expect(record[:amount_calculation_run_snapshot]).to eq(snapshot)
      expect(record[:summaries][:final_result]).not_to have_key('amount_calculation_run_snapshot')
      expect(retry_record[:run]).not_to be_readonly
      expect(retry_record[:run].final_result_summary).to have_key('amount_calculation_run_snapshot')
    end
  end

  it 'summary専用recordをretry可否や詳細の取得へ混用しない' do
    expect { described_class.call(summary_only: true, include_retry_options: true) }.to raise_error(ArgumentError)
    expect { described_class.call(summary_only: true, include_amount_profile: true) }.to raise_error(ArgumentError)
  end

  it '一覧専用projectionの関連取得は件数増加でN+1にならない' do
    run = create(:receipt_analysis_run, :succeeded)
    count = lambda do |&block|
      queries = []
      subscriber = lambda do |_name, _started, _finished, _id, payload|
        queries << payload[:sql] if payload[:sql].start_with?('SELECT') && payload[:name] != 'SCHEMA'
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &block)
      queries.size
    end
    one = count.call { described_class.call(run_key: run.run_key, summary_only: true) }
    create_list(:receipt_analysis_run, 4, :succeeded)
    many = count.call { described_class.call(summary_only: true) }

    expect(many).to eq(one)
  end

  it '不正なouter summaryも一覧・詳細でraw表示せず扱う' do
    run = create(:receipt_analysis_run, :succeeded)
    [ nil, 'PRIVATE_OUTER', [ 'PRIVATE_OUTER' ], 42 ].each do |value|
      ReceiptAnalysisRun.where(id: run.id).update_all([ 'final_result_summary = ?::jsonb', JSON.generate(value) ])
      summary = described_class.call(run_key: run.run_key, summary_only: true).records.fetch(0)
      detail = described_class.call(run_key: run.run_key, include_amount_profile: true).records.fetch(0)

      expect(summary[:summaries][:final_result]).to eq({})
      expect(detail[:summaries][:final_result]).to eq({})
      expect(detail[:amount_calculation_run_snapshot]).to be_nil
    end
  end
end
