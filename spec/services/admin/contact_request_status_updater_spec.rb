require 'rails_helper'

RSpec.describe Admin::ContactRequestStatusUpdater do
  include ActiveSupport::Testing::TimeHelpers

  describe '.call' do
    it 'statusと担当者を更新し、変更内容をAuditLogへ記録する' do
      admin = create(:user, :admin)
      contact_request = create(:contact_request, status: 'open')

      travel_to(Time.zone.parse('2026-07-12 12:00:00')) do
        expect {
          @result = described_class.call(
            contact_request: contact_request,
            status: 'in_progress',
            actor: admin,
            request: nil
          )
        }.to change(AuditLog, :count).by(1)

        audit_log = AuditLog.last

        aggregate_failures do
          expect(@result).to be_success
          expect(@result.contact_request).to eq(contact_request)
          expect(@result.error_code).to be_nil
          expect(contact_request.reload).to have_attributes(
            status: 'in_progress',
            handled_by_user: admin,
            handled_at: Time.current
          )
          expect(audit_log).to have_attributes(
            actor_user: admin,
            actor_kind: 'admin',
            action: 'admin.contact_requests.status_update',
            target_type: 'ContactRequest',
            target_id: contact_request.id,
            target_uid: contact_request.request_uid,
            outcome: 'succeeded'
          )
          expect(audit_log.before_state).to eq('status' => 'open')
          expect(audit_log.after_state).to eq('status' => 'in_progress')
        end
      end
    end

    it 'AuditLogへ問い合わせ本文やemail全文を保存しない' do
      admin = create(:user, :admin)
      contact_request = create(
        :contact_request,
        email: 'sender-secret@example.com',
        subject: 'AuditLogへ入れない件名',
        body: 'AuditLogへ入れない本文',
        category: 'security'
      )

      described_class.call(
        contact_request: contact_request,
        status: 'resolved',
        actor: admin,
        request: nil
      )

      audit_log = AuditLog.last
      audit_json = audit_log.attributes.slice('metadata', 'before_state', 'after_state').to_json

      aggregate_failures do
        expect(audit_log.metadata).to include(
          'request_uid' => contact_request.request_uid,
          'old_status' => 'open',
          'new_status' => 'resolved',
          'category' => 'security',
          'user_id' => contact_request.user_id,
          'email_digest' => contact_request.email_digest
        )
        expect(audit_json).not_to include('sender-secret@example.com')
        expect(audit_json).not_to include('AuditLogへ入れない件名')
        expect(audit_json).not_to include('AuditLogへ入れない本文')
      end
    end

    it '未知statusは更新もAuditLog記録もしない' do
      admin = create(:user, :admin)
      contact_request = create(:contact_request, status: 'open')

      expect {
        @result = described_class.call(
          contact_request: contact_request,
          status: 'deleted',
          actor: admin,
          request: nil
        )
      }.not_to change(AuditLog, :count)

      aggregate_failures do
        expect(@result).not_to be_success
        expect(@result.error_code).to eq('invalid_status')
        expect(contact_request.reload).to have_attributes(
          status: 'open',
          handled_by_user: nil,
          handled_at: nil
        )
      end
    end

    it 'AuditLog validation失敗時は更新をrollbackして失敗Resultを返す' do
      admin = create(:user, :admin)
      contact_request = create(:contact_request, status: 'open')
      audit_error = ActiveRecord::RecordInvalid.new(AuditLog.new)
      allow(AuditLogs).to receive(:record_admin_action!).and_raise(audit_error)

      result = described_class.call(
        contact_request: contact_request,
        status: 'in_progress',
        actor: admin,
        request: nil
      )

      aggregate_failures do
        expect(result).not_to be_success
        expect(result.error_code).to eq('validation_failed')
        expect(contact_request.reload).to have_attributes(
          status: 'open',
          handled_by_user: nil,
          handled_at: nil
        )
        expect(AuditLog).not_to exist(action: 'admin.contact_requests.status_update')
      end
    end

    it '予期しないAuditLog失敗は更新をrollbackして呼び出し元へ伝播する' do
      admin = create(:user, :admin)
      contact_request = create(:contact_request, status: 'open')
      allow(AuditLogs).to receive(:record_admin_action!).and_raise(StandardError, 'audit failed')

      expect {
        described_class.call(
          contact_request: contact_request,
          status: 'in_progress',
          actor: admin,
          request: nil
        )
      }.to raise_error(StandardError, 'audit failed')

      aggregate_failures do
        expect(contact_request.reload).to have_attributes(
          status: 'open',
          handled_by_user: nil,
          handled_at: nil
        )
        expect(AuditLog).not_to exist(action: 'admin.contact_requests.status_update')
      end
    end
  end
end
