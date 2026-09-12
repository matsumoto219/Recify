require 'rails_helper'
require_relative '../../support/current_amount_inspector_helpers'

RSpec.describe 'Admin current amount inspector', type: :request do
  include ActiveJob::TestHelper
  include CurrentAmountInspectorHelpers

  let(:admin) { create(:user, :admin) }
  let(:receipt) { create(:receipt, :completed, amount_calculation_profile: current_amount_profile) }
  let(:run) { create(:receipt_analysis_run, :succeeded, receipt:) }

  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    original_show_detailed_exceptions = Rails.application.env_config['action_dispatch.show_detailed_exceptions']
    original_adapter = ActiveJob::Base.queue_adapter

    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs

    example.run
  ensure
    clear_enqueued_jobs
    ActiveJob::Base.queue_adapter = original_adapter
    Rails.application.env_config['action_dispatch.show_exceptions'] = original_show_exceptions
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = original_show_detailed_exceptions
  end

  def inspector_node
    Nokogiri::HTML(response.body).at_css('[data-current-amount-inspector]')
  end

  it '既存admin認証だけで現在値を表示し閲覧のための再認証を要求しない' do
    sign_in admin

    get admin_receipt_analysis_run_path(run.run_key)

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(inspector_node).to be_present
      expect(inspector_node.text).to include(I18n.t('admin.current_amount_inspector.title'))
      expect(inspector_node.css('form, input, button, a[download]')).to be_empty
      expect(session[:admin_passkey_reauthenticated_at]).to be_nil
    end
  end

  it 'run作成後に更新されたReceiptの現在profileを表示しrun当時値を再構成しない' do
    run
    sign_in admin
    get admin_receipt_analysis_run_path(run.run_key)
    expect(inspector_node.text).to include('1100')
    updated_profile = current_amount_profile.merge(
      'context' => 'edit_save',
      'computed' => { 'total_amount' => 2378 },
      'resolved' => { 'total_amount' => 2378 }
    ).except('amount_engine', 'score', 'selected_candidate_status')
    receipt.update!(amount_calculation_profile: updated_profile)

    get admin_receipt_analysis_run_path(run.run_key)

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(inspector_node.text).to include('2378')
      expect(inspector_node.text).not_to include('1100')
      expect(inspector_node.text).to include(I18n.t('admin.current_amount_inspector.values.edit_save'))
      expect(run.reload.final_result_summary).to be_empty
    end
  end

  it '閲覧でReceipt/run/設定/監査を更新せず計算・provider・jobを実行しない' do
    run
    sign_in admin
    clear_enqueued_jobs
    original_receipt = receipt.reload.attributes
    original_run = run.reload.attributes
    expect(ReceiptAmountService).not_to receive(:call)
    expect(ReceiptOcrService).not_to receive(:call)
    expect(ReceiptAiEnrichmentService).not_to receive(:call)
    expect(AuditLogs).not_to receive(:record_admin_action!)
    mutations = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      sql = payload[:sql]
      next unless sql.match?(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i)
      next unless sql.match?(/"(?:receipts|receipt_items|receipt_analysis_runs|system_settings|audit_logs)"/)

      mutations << sql
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      get admin_receipt_analysis_run_path(run.run_key)
    end

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(mutations).to be_empty
      expect(enqueued_jobs).to be_empty
      expect(receipt.reload.attributes).to eq(original_receipt)
      expect(run.reload.attributes).to eq(original_run)
    end
  end

  it '既知key内の機微文字列と未知keyをInspectorへ出さずHTMLを実行しない' do
    profile = current_amount_profile
    sentinel = '<script>private-source@example.invalid</script>'
    profile['context'] = sentinel
    profile['computed']['total_amount'] = sentinel
    profile['profile']['tax_detail_amount_basis'] = sentinel
    profile['raw_response'] = sentinel
    candidate = profile['amount_engine']['selected_candidate']
    candidate['candidate_id'] = sentinel
    candidate['evidence'].first.merge!('source' => sentinel, 'source_text' => sentinel)
    candidate['computed_items'].first.merge!('price' => sentinel, 'name' => sentinel)
    receipt.update!(amount_calculation_profile: profile)
    sign_in admin

    get admin_receipt_analysis_run_path(run.run_key)

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(inspector_node).to be_present
      expect(inspector_node.to_html).not_to include('private-source', 'raw_response', 'source_text')
      expect(inspector_node.css('script')).to be_empty
      expect(receipt.reload.amount_calculation_profile).to eq(profile)
    end
  end

  it '未知versionはraw dumpせず表示不可として扱う' do
    receipt.update!(amount_calculation_profile: { schema_version: 99, source_text: 'private-unavailable-value' })
    sign_in admin

    get admin_receipt_analysis_run_path(run.run_key)

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(inspector_node).to be_present
      expect(inspector_node.to_html).not_to include('private-unavailable-value', 'source_text')
      expect(inspector_node.css('pre')).to be_empty
    end
  end

  [ :unauthenticated, :non_admin, :guest_admin ].each do |identity|
    it "#{identity}にはInspectorを出さず404を返す" do
      user = case identity
      when :non_admin then create(:user)
      when :guest_admin then create(:user, :admin, guest: true)
      end
      sign_in user if user

      get admin_receipt_analysis_run_path(run.run_key)

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(inspector_node).to be_nil
      end
    end
  end

  it 'locked adminには既存認証のredirectを維持しInspectorを出さない' do
    sign_in create(:user, :admin, locked_at: Time.current)

    get admin_receipt_analysis_run_path(run.run_key)

    aggregate_failures do
      expect(response).to have_http_status(:redirect)
      expect(inspector_node).to be_nil
    end
  end
end
