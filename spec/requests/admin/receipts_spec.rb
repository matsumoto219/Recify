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
      receipt = create(:receipt, :with_image, :completed, store_name: '管理確認ストア')
      receipt.receipt_items.create!(confirmed_name: 'コーヒー', line_total: 300, position_index: 1)
      create(:receipt_analysis_run, receipt: receipt)
      sign_in admin
      stub_fresh_admin_reauthentication

      get admin_receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('レシート詳細')
        expect(response.body).to include('管理確認ストア')
        expect(response.body).to include('通常表示')
        expect(response.body).to include('レシートを隔離')
        expect(response.body).to include('確認文字列 QUARANTINE RECEIPT')
        expect(response.body).to include(quarantine_admin_receipt_path(receipt))
        expect(response.body).to include(admin_user_path(receipt.user))
        expect(response.body).to include(admin_receipt_analysis_runs_path(receipt_public_id: receipt.public_id))
        expect(response.body).to include(admin_audit_logs_path(target_uid: "receipt:#{receipt.public_id}"))
        expect(response.body.scan(/translation missing[^<]*/)).to be_empty
      end
    end

    it 'adminはquarantined receiptを確認して解除導線を見られる' do
      admin = create(:user, :admin)
      receipt = create(:receipt, :quarantined, quarantined_by: admin, quarantine_reason: 'policy violation')
      sign_in admin
      stub_fresh_admin_reauthentication

      get admin_receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('隔離中')
        expect(response.body).to include('policy violation')
        expect(response.body).to include('隔離を解除')
        expect(response.body).to include('確認文字列 RELEASE RECEIPT')
        expect(response.body).to include(release_admin_receipt_path(receipt))
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
end
