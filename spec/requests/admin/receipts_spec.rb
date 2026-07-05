# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin receipts', type: :request do
  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    original_show_detailed_exceptions = Rails.application.env_config['action_dispatch.show_detailed_exceptions']

    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false

    example.run
  ensure
    Rails.application.env_config['action_dispatch.show_exceptions'] = original_show_exceptions
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = original_show_detailed_exceptions
  end

  def comparable_headers
    response.headers.to_h.except('x-request-id', 'x-runtime')
  end

  def stub_fresh_admin_reauthentication
    allow_any_instance_of(Admin::ReceiptsController).to receive(:admin_passkey_reauthenticated?).and_return(true)
    allow_any_instance_of(Admin::ReceiptsController).to receive(:admin_reauthentication_context).and_return(
      method: 'passkey',
      reauthenticated_at: Time.current
    )
  end

  describe 'GET /admin/receipts/:public_id' do
    it '非ログインユーザーには既存404と同じbody/headerを返す' do
      receipt = create(:receipt)

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      get admin_receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).not_to include('レシート詳細')
      end
    end

    it '一般ユーザーには既存404と同じbody/headerを返す' do
      user = create(:user)
      receipt = create(:receipt, user: user)
      sign_in user

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      sign_in user
      get admin_receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).not_to include('レシート詳細')
      end
    end

    it 'adminはactive receiptの詳細と隔離導線を見られる' do
      admin = create(:user, :admin)
      owner = create(
        :user,
        email: 'recify-admin-owner-super-long-local-part-version12345678901234567890@example-admin-owner-long-domain.example.com'
      )
      receipt = create(:receipt, :with_image, :completed, user: owner, store_name: '管理確認ストア')
      receipt.receipt_items.create!(confirmed_name: 'コーヒー', line_total: 300, position_index: 1)
      create(:receipt_analysis_run, receipt: receipt)
      sign_in admin
      stub_fresh_admin_reauthentication

      get admin_receipt_path(receipt)
      document = Nokogiri::HTML(response.body)
      owner_email_node = document.css('[data-email-address-display]').find { |node| node['title'] == owner.email }
      owner_email_section = owner_email_node&.ancestors&.find { |node| node.name == 'section' }
      owner_email_segments = owner_email_node&.css('span') || []

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('レシート詳細')
        expect(response.body).to include('管理確認ストア')
        expect(response.body).to include('通常表示')
        expect(response.body).to include('レシートを隔離')
        expect(response.body).to include('確認文字列 QUARANTINE RECEIPT')
        expect(response.body).to include('レシートを完全削除')
        expect(response.body).to include('確認文字列 HARD DELETE RECEIPT')
        expect(response.body).to include(quarantine_admin_receipt_path(receipt))
        expect(response.body).to include(hard_delete_admin_receipt_path(receipt))
        expect(response.body).to include(admin_user_path(receipt.user))
        expect(response.body).to include(admin_receipt_analysis_runs_path(receipt_public_id: receipt.public_id))
        expect(response.body).to include(admin_audit_logs_path(target_uid: "receipt:#{receipt.public_id}"))
        expect(response.body.scan(/translation missing[^<]*/)).to be_empty
        expect(owner_email_node).to be_present
        expect(owner_email_node['class'].split).to include('w-full', 'overflow-hidden')
        expect(owner_email_section['class'].split).to include('min-w-0', 'max-w-full')
        expect(owner_email_segments.map { |segment| segment.text.strip }).to include('@')
      end
    end

    it 'adminはquarantined receiptを確認して解除導線を見られる' do
      admin = create(
        :user,
        :admin,
        email: 'recify-admin-quarantine-long-local-part-version12345678901234567890@example-admin-action-long-domain.example.com'
      )
      receipt = create(:receipt, :quarantined, quarantined_by: admin, quarantine_reason: 'policy violation')
      sign_in admin
      stub_fresh_admin_reauthentication

      get admin_receipt_path(receipt)
      document = Nokogiri::HTML(response.body)
      moderator_email_node = document.css('[data-email-address-display]').find { |node| node['title'] == admin.email }
      moderator_reference = moderator_email_node&.ancestors&.find { |node| node['class'].to_s.split.include?('items-baseline') }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('隔離中')
        expect(response.body).to include('policy violation')
        expect(response.body).to include('隔離を解除')
        expect(response.body).to include('確認文字列 RELEASE RECEIPT')
        expect(response.body).to include(release_admin_receipt_path(receipt))
        expect(moderator_email_node).to be_present
        expect(moderator_email_node['class'].split).to include('flex-1', 'overflow-hidden')
        expect(moderator_reference['class'].split).to include('flex', 'min-w-0', 'max-w-full')
      end
    end
  end

  describe 'POST /admin/receipts/:public_id/quarantine' do
    it 'fresh reauthなしではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      receipt = create(:receipt)
      sign_in admin
      allow(SystemOperations).to receive(:execute_receipt_moderation_operation)

      post quarantine_admin_receipt_path(receipt),
           params: { reason: 'policy violation', confirmation: 'QUARANTINE RECEIPT' }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_receipt_path(receipt)))
        expect(SystemOperations).not_to have_received(:execute_receipt_moderation_operation)
      end
    end

    it 'reason blankではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      receipt = create(:receipt)
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:execute_receipt_moderation_operation)

      post quarantine_admin_receipt_path(receipt),
           params: { reason: ' ', confirmation: 'QUARANTINE RECEIPT' }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_path(receipt))
        expect(SystemOperations).not_to have_received(:execute_receipt_moderation_operation)
      end
    end

    it 'confirmation blankではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      receipt = create(:receipt)
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:execute_receipt_moderation_operation)

      post quarantine_admin_receipt_path(receipt),
           params: { reason: 'policy violation', confirmation: ' ' }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_path(receipt))
        expect(SystemOperations).not_to have_received(:execute_receipt_moderation_operation)
      end
    end

    it 'SystemOperations経由で隔離し、AuditLogを残し、画像をpurgeしない' do
      admin = create(:user, :admin)
      receipt = create(:receipt, :with_image)
      source = create(:security_event)
      blob_id = receipt.image.blob.id
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post quarantine_admin_receipt_path(receipt),
             params: {
               reason: 'policy violation',
               confirmation: 'QUARANTINE RECEIPT',
               source_security_event_id: source.id
             }
      end.to change(AuditLog.where(action: 'admin.receipts.quarantine', outcome: 'succeeded'), :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_path(receipt))
        expect(receipt.reload).to have_attributes(
          moderation_status: 'quarantined',
          quarantined_by: admin,
          quarantine_reason: 'policy violation',
          quarantine_source_security_event: source
        )
        expect(receipt.image).to be_attached
        expect(ActiveStorage::Blob.exists?(blob_id)).to be(true)
        expect(AuditLog.last).to have_attributes(target_uid: "receipt:#{receipt.public_id}", reason: 'policy violation')
        expect(AuditLog.last.metadata).to include('reauthenticated' => true, 'source_security_event_id' => source.id)
      end
    end

    it 'quarantined receiptは再隔離しない' do
      admin = create(:user, :admin)
      receipt = create(:receipt, :quarantined)
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:execute_receipt_moderation_operation)

      post quarantine_admin_receipt_path(receipt),
           params: { reason: 'policy violation', confirmation: 'QUARANTINE RECEIPT' }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_path(receipt))
        expect(SystemOperations).not_to have_received(:execute_receipt_moderation_operation)
      end
    end
  end

  describe 'POST /admin/receipts/:public_id/release' do
    it 'SystemOperations経由で隔離を解除し、AuditLogを残す' do
      admin = create(:user, :admin)
      receipt = create(:receipt, :quarantined, quarantine_reason: 'policy violation')
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post release_admin_receipt_path(receipt),
             params: { reason: 'false positive', confirmation: 'RELEASE RECEIPT' }
      end.to change(AuditLog.where(action: 'admin.receipts.release', outcome: 'succeeded'), :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_path(receipt))
        expect(receipt.reload).to have_attributes(
          moderation_status: 'active',
          quarantine_released_by: admin,
          quarantine_released_reason: 'false positive'
        )
        expect(receipt.quarantine_reason).to eq('policy violation')
        expect(AuditLog.last).to have_attributes(target_uid: "receipt:#{receipt.public_id}", reason: 'false positive')
      end
    end

    it 'active receiptはreleaseしない' do
      admin = create(:user, :admin)
      receipt = create(:receipt)
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:execute_receipt_moderation_operation)

      post release_admin_receipt_path(receipt),
           params: { reason: 'false positive', confirmation: 'RELEASE RECEIPT' }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_path(receipt))
        expect(SystemOperations).not_to have_received(:execute_receipt_moderation_operation)
        expect(receipt.reload).to be_moderation_active
      end
    end
  end

  describe 'POST /admin/receipts/:public_id/hard_delete' do
    it 'fresh reauthなしではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      receipt = create(:receipt, :with_image, :processing)
      sign_in admin
      allow(SystemOperations).to receive(:execute_receipt_moderation_operation)

      post hard_delete_admin_receipt_path(receipt),
           params: { reason: 'stuck processing cleanup', confirmation: 'HARD DELETE RECEIPT' }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_receipt_path(receipt)))
        expect(SystemOperations).not_to have_received(:execute_receipt_moderation_operation)
        expect(receipt.reload).to be_present
      end
    end

    it 'reason blankではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      receipt = create(:receipt, :failed)
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:execute_receipt_moderation_operation)

      post hard_delete_admin_receipt_path(receipt),
           params: { reason: ' ', confirmation: 'HARD DELETE RECEIPT' }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_path(receipt))
        expect(SystemOperations).not_to have_received(:execute_receipt_moderation_operation)
      end
    end

    it 'processing状態でも強制削除し、owner詳細へ戻し、AuditLogを残す' do
      admin = create(:user, :admin)
      receipt = create(:receipt, :with_image, :processing)
      create(:receipt_analysis_run, :running, receipt: receipt)
      receipt.receipt_items.create!(confirmed_name: 'テスト品', line_total: 100, position_index: 1)
      owner = receipt.user
      public_id = receipt.public_id
      receipt_id = receipt.id
      attachment_id = receipt.image.attachment.id
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post hard_delete_admin_receipt_path(receipt),
             params: { reason: 'stuck processing cleanup', confirmation: 'HARD DELETE RECEIPT' }
      end.to change(AuditLog.where(action: 'admin.receipts.hard_delete', outcome: 'succeeded'), :count).by(1)
        .and change(Receipt, :count).by(-1)
        .and change(ReceiptAnalysisRun, :count).by(-1)
        .and change(ReceiptItem, :count).by(-1)

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(owner))
        expect(Receipt.exists?(receipt_id)).to be(false)
        expect(ActiveStorage::Attachment.exists?(attachment_id)).to be(false)
        expect(AuditLog.last).to have_attributes(target_uid: "receipt:#{public_id}", reason: 'stuck processing cleanup')
        expect(AuditLog.last.before_state).to include(
          'receipt_id' => receipt_id,
          'receipt_public_id' => public_id,
          'receipt_status' => 'processing',
          'image_attached' => true,
          'related_records' => include('analysis_runs' => 1, 'items' => 1)
        )
        expect(AuditLog.last.after_state).to eq('deleted' => true)
        expect(AuditLog.last.metadata).to include('operation' => 'hard_delete', 'deleted' => true)
        expect(AuditLog.last.attributes.to_json).not_to include('テスト品', 'raw_text', 'ocr_result_snapshot', 'ai_result_summary')
      end
    end
  end
end
