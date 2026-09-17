require 'rails_helper'
require_relative '../../support/run_amount_inspector_helpers'

RSpec.describe 'Admin run amount inspector', type: :request do
  include ActiveJob::TestHelper
  include RunAmountInspectorHelpers

  let(:admin) { create(:user, :admin) }
  let(:receipt) { create(:receipt, :completed, amount_calculation_profile: current_amount_profile) }
  let(:snapshot) { run_amount_snapshot }
  let(:run) do
    create(:receipt_analysis_run, :succeeded, receipt: receipt,
      final_result_summary: { schema_version: 'v1', receipt_status: 'review_needed', amount_calculation_run_snapshot: snapshot })
  end

  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    example.run
  ensure
    Rails.application.env_config['action_dispatch.show_exceptions'] = original_show_exceptions
  end

  def inspector_node
    Nokogiri::HTML(response.body).at_css('[data-run-amount-inspector]')
  end

  it '既存admin認証で6sectionと履歴判定・省略内容を表示しCurrentと区別する' do
    sign_in admin
    expect(Receipts::Processing).to receive(:amount_calculation_run_snapshot).once.and_call_original

    get admin_receipt_analysis_run_path(run.run_key)

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(inspector_node.css('[data-amount-inspector-section]').size).to eq(6)
      expect(inspector_node.text).to include('解析当時の計算', '当時の金額計算による要確認判定', '元件数', '省略件数')
      expect(inspector_node.text).to include('警告ごとの確認必須・診断のみの分類は未記録')
      expect(inspector_node.text).to include('正解の確率やAIの確信度ではありません')
      expect(inspector_node.text).to include('131072', '最終保存したレシート金額・状態')
      expect(inspector_node.text).not_to match(/translation missing/i)
      expect(inspector_node.css('form, input, button, a[download], pre')).to be_empty
      expect(Nokogiri::HTML(response.body).css('pre').map(&:text).join).not_to include('amount_calculation_run_snapshot')
      expect(session[:admin_passkey_reauthenticated_at]).to be_nil
    end
  end

  it '後続編集はCurrentだけを更新し履歴は当時の金額を表示する' do
    run
    receipt.update!(amount_calculation_profile: current_amount_profile.merge(
      'context' => 'edit_save', 'computed' => { 'total_amount' => 2378 }, 'resolved' => { 'total_amount' => 2378 }
    ).except('amount_engine'))
    sign_in admin

    get admin_receipt_analysis_run_path(run.run_key)

    aggregate_failures do
      expect(inspector_node.text).to include('1100')
      expect(inspector_node.text).not_to include('2378')
      expect(Nokogiri::HTML(response.body).at_css('[data-current-amount-inspector]').text).to include('2378')
      expect(run.reload.final_result_summary['amount_calculation_run_snapshot']).to eq(snapshot)
    end
  end

  it '旧run・不正snapshotは安全に利用不可としraw値やCurrentを履歴へ出さない' do
    run
    sign_in admin
    [ nil, { 'schema_version' => 'unknown', 'source_text' => '<script>PRIVATE_RAW</script>' },
      snapshot.deep_merge('engine' => { 'computed' => { 'total_amount' => 'PRIVATE_SECRET' } }) ].each do |value|
      run.update!(final_result_summary: { amount_calculation_run_snapshot: value })
      get admin_receipt_analysis_run_path(run.run_key)

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(inspector_node.text).to include('利用できません', '現在の計算から補完しません')
        expect(inspector_node.text).not_to include('1100', 'PRIVATE_', 'source_text')
        expect(response.body).not_to include('PRIVATE_RAW', 'PRIVATE_SECRET')
        expect(inspector_node.css('script')).to be_empty
      end
    end
  end

  it '閲覧は書込み・計算・provider・enqueue・監査を追加しない' do
    run
    sign_in admin
    original_receipt = receipt.reload.attributes
    original_run = run.reload.attributes
    expect(ReceiptAmountService).not_to receive(:call)
    expect(ReceiptOcrService).not_to receive(:call)
    expect(ReceiptAiEnrichmentService).not_to receive(:call)
    expect(ReceiptFinalizeJob).not_to receive(:perform_later)
    expect(AuditLogs).not_to receive(:record_admin_action!)
    mutations = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      sql = payload[:sql]
      mutations << sql if sql.match?(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i) &&
        sql.match?(/"(?:receipts|receipt_items|receipt_analysis_runs|system_settings|audit_logs)"/)
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      get admin_receipt_analysis_run_path(run.run_key)
    end

    expect(response).to have_http_status(:ok)
    expect(mutations).to be_empty
    expect(receipt.reload.attributes).to eq(original_receipt)
    expect(run.reload.attributes).to eq(original_run)
  end

  it 'indexとstatusはSQL段階で詳細snapshotを除外しreaderを起動しない' do
    run
    sign_in admin
    expect(Receipts::Processing).not_to receive(:amount_calculation_run_snapshot)
    queries = []
    subscriber = ->(_name, _started, _finished, _id, payload) { queries << payload[:sql] }
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      get admin_receipt_analysis_runs_path, params: { user_id: receipt.user_id }
      expect(response).to have_http_status(:ok)
      expect(inspector_node).to be_nil
      get status_admin_receipt_analysis_runs_path, params: { run_keys: [ run.run_key ] }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch('runs').first.fetch('run_key')).to eq(run.run_key)
    end
    selects = queries.grep(/SELECT.*FROM "receipt_analysis_runs"/).reject { |sql| sql.include?('COUNT(') }

    expect(selects.size).to eq(2)
    expect(selects).to all(include("\"final_result_summary\" - 'amount_calculation_run_snapshot'"))
    expect(selects).not_to include(a_string_matching(/"receipt_analysis_runs"\.\*/))
    expect(response.body).not_to include('amount_calculation_run_snapshot')
  end

  it '非管理者には履歴Inspectorを出さず404を返す' do
    sign_in create(:user)

    get admin_receipt_analysis_run_path(run.run_key)

    expect(response).to have_http_status(:not_found)
    expect(inspector_node).to be_nil
  end
end
