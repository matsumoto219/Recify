require 'rails_helper'

RSpec.describe 'Receipt processing notification delivery' do
  self.use_transactional_tests = false

  def successful_ocr_result
    {
      success: true,
      lines: [ '検証ストア', '2026/05/23 10:00', 'コーヒー 180', '合計 180', '現金' ],
      candidates: {
        store_name: '検証ストア',
        purchased_at_text: '2026/05/23 10:00',
        total_amount: 180,
        country_region: 'JPN',
        payment_method_text: '現金',
        items: [ { raw_text: 'コーヒー', price: 180, quantity: 1, line_total: 180, confidence: 0.95 } ],
        payments: [ { method: 'Cash', amount: 180 } ],
        tax_details: []
      },
      meta: { provider: 'azure_document_intelligence', model_id: 'prebuilt-receipt' }
    }
  end

  def build_ready_run(source: 'upload', serialized: false, strategy: 'ai_success')
    if serialized
      @setting = create(
        :system_setting,
        key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
        value: SystemSettings.stored_value(true)
      )
      @run = Receipts::Processing.start(receipt: @receipt, source:).run
      raw = JSON.parse(
        Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
      )
      ocr_result = Ocr::ResponseParser.new(response: raw, provider: :fixture).call
    else
      @run = create(:receipt_analysis_run, receipt: @receipt, source:)
      ocr_result = successful_ocr_result
      allow(ReceiptAmountService).to receive(:call).and_return(
        resolved: { total: 180, subtotal: 164, tax: 16, tax_rate: BigDecimal('0.1') },
        computed: { items: [] },
        tax_details: [],
        inconsistencies: [],
        blocking_inconsistencies: [],
        warning_inconsistencies: [],
        mismatch_codes: [],
        blocking_mismatch_codes: [],
        warning_mismatch_codes: [],
        warning_reasons: [],
        mismatch_messages: [],
        needs_review: false
      )
    end

    Receipts::Processing.record_ocr_snapshot(@run, ocr_result)
    Receipts::Processing.record_ai_normalized_result(
      @run,
      {
        success: true,
        needs_review: false,
        receipt_attributes: { payment_method: 'cash' },
        receipt_items_attributes: [ { index: 0, category: 'drink', needs_review: false } ]
      }
    ) if strategy == 'ai_success'
    Receipts::Processing.record_finalize_decision(
      @run,
      Receipts::Processing::Contracts::FinalizeDecision.new(
        finalize_strategy: strategy,
        error_code: strategy == 'fail_receipt' ? 'ocr_api_error' : nil,
        error_message: nil,
        receipt_attributes: {},
        ocr_result: nil,
        ai_result: nil,
        metadata: {}
      )
    )
    @run.reload
    @broadcasts.clear
  end

  def expect_terminal_delivery(status, item_count:)
    notification = @user.notifications.sole
    aggregate_failures do
      expect(@receipt.reload.status).to eq(status)
      expect(notification).to have_attributes(kind: "receipt_#{status}", notifiable: @receipt)
      expect(@run.reload).to have_attributes(status: 'succeeded')
      expect(@run.final_result_summary).to include('receipt_status' => status, 'item_count' => item_count)
      expect(@broadcasts.count { |broadcast| broadcast[:target] == @receipt.dom_target_id && broadcast[:status] == status }).to eq(1)
      expect(@broadcasts.count { |broadcast| broadcast[:target] == 'toast-stream' }).to eq(1)
      expect(@broadcasts).to include(include(target: 'receipts_summary'))
      expect(@broadcasts).to include(include(target: 'notifications_unread_badge'))
    end
  end

  before do
    @broadcasts = []
    allow(Turbo::StreamsChannel).to receive(:broadcast_action_later_to).and_wrap_original do |original, *streams, **options|
      @broadcasts << { target: options[:target], status: options.dig(:locals, :receipt)&.status }
      original.call(*streams, **options)
    end
    @receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    @user = @receipt.user
  end

  after do
    blob_ids = ActiveStorage::Attachment.where(
      record_type: 'Receipt',
      record_id: @receipt&.id,
      name: 'image'
    ).pluck(:blob_id)
    Receipt.where(id: @receipt&.id).destroy_all
    ActiveStorage::Blob.where(id: blob_ids).find_each(&:purge)
    SystemSetting.where(id: @setting&.id).delete_all
    User.where(id: @user&.id).destroy_all
  end

  %w[upload batch_upload admin_retry].each do |source|
    it "#{source}のFinalize commit後に完了通知と画面更新を一度だけ配信する" do
      build_ready_run(source:)

      expect(Receipts::Processing.run_finalize(@run).next_step).to eq(:done)

      expect_terminal_delivery('completed', item_count: 1)
    end
  end

  it '通常Finalizeの失敗結果を通知する' do
    build_ready_run(strategy: 'fail_receipt')

    Receipts::Processing.run_finalize(@run)

    expect_terminal_delivery('failed', item_count: 0)
  end

  it '直列化Finalizeの要確認結果をcommit後に通知する' do
    build_ready_run(serialized: true, strategy: 'ocr_only')
    expect(Receipts::Processing::ReferencePricingAutoAdoptionFence.serialization_required?(@run)).to be(true)

    Receipts::Processing.run_finalize(@run)

    expect_terminal_delivery('review_needed', item_count: 1)
  end

  it '直列化Finalizeの失敗結果をcommit後に通知する' do
    build_ready_run(serialized: true, strategy: 'fail_receipt')
    expect(Receipts::Processing::ReferencePricingAutoAdoptionFence.serialization_required?(@run)).to be(true)

    Receipts::Processing.run_finalize(@run)

    expect_terminal_delivery('failed', item_count: 0)
  end

  it '通知OFFでも永続通知とカードを更新し、レシートの一時メッセージだけ止める' do
    @user.update!(push_notification_enabled: false)
    build_ready_run

    Receipts::Processing.run_finalize(@run)

    aggregate_failures do
      expect(@user.notifications.sole.kind).to eq('receipt_completed')
      expect(@broadcasts).to include(include(target: @receipt.dom_target_id, status: 'completed'))
      expect(@broadcasts).to include(include(target: 'notifications_unread_badge'))
      expect(@broadcasts).not_to include(include(target: 'toast-stream'))
    end
  end

  it '外側transactionが確定するまでは終端通知を配信しない' do
    build_ready_run

    ReceiptAnalysisRun.transaction do
      Receipts::Processing.run_finalize(@run)

      expect(@user.notifications).to be_empty
      expect(@broadcasts).to be_empty
    end

    expect_terminal_delivery('completed', item_count: 1)
  end

  [ false, true ].each do |serialized|
    context "serialized=#{serialized}" do
      it 'Finalize jobを再実行しても終端通知を重複配信しない' do
        build_ready_run(serialized:, strategy: serialized ? 'ocr_only' : 'ai_success')
        Receipts::Processing.run_finalize(@run)
        expect(@user.notifications.count).to eq(1)
        @broadcasts.clear

        result = Receipts::Processing.run_finalize(@run.reload)

        aggregate_failures do
          expect(result.next_step).to eq(:skipped)
          expect(@user.notifications.count).to eq(1)
          expect(@broadcasts).to be_empty
        end
      end

      it '最終summary保存失敗では未commitの終端通知を出さず失敗通知だけ配信する' do
        build_ready_run(serialized:, strategy: serialized ? 'ocr_only' : 'ai_success')
        original_total = @receipt.total_amount
        allow(Receipts::Processing).to receive(:record_final_result).and_raise('summary write failed')

        expect { Receipts::Processing.run_finalize(@run) }.to raise_error('summary write failed')

        aggregate_failures do
          expect(@receipt.reload).to have_attributes(status: 'failed', total_amount: original_total)
          expect(@receipt.receipt_items).to be_empty
          expect(@run.reload.status).to eq('failed')
          expect(@run.final_result_summary).to be_empty
          expect(@user.notifications.sole.kind).to eq('receipt_failed')
          expect(@broadcasts).not_to include(include(target: @receipt.dom_target_id, status: 'completed'))
          expect(@broadcasts).not_to include(include(target: @receipt.dom_target_id, status: 'review_needed'))
          expect(@broadcasts.count { |broadcast| broadcast[:target] == 'toast-stream' }).to eq(1)
        end
      end
    end
  end
end
