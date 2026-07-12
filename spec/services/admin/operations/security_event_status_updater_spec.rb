require 'rails_helper'

RSpec.describe Admin::Operations::SecurityEventStatusUpdater do
  describe '.call' do
    it 'resolvedに更新し、AuditLogへpayloadなしで記録する' do
      admin = create(:user, :admin)
      event = create(:security_event, event_type: 'xss_attempt', severity: 'high', payload_excerpt: '<script>alert(1)</script>')

      result = described_class.call(security_event: event, status: :resolved, actor: admin, request: nil)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_updated
        expect(result).to be_frozen
        expect { result.updated = false }.to raise_error(NoMethodError)
        expect(event.reload.resolved_at).to be_present
        expect(event.ignored_at).to be_nil
        expect(audit_log).to have_attributes(
          actor_user_id: admin.id,
          action: 'admin.security_events.resolved',
          outcome: 'succeeded',
          target_uid: "security_event:#{event.id}"
        )
        expect(audit_log.metadata).to include('event_type' => 'xss_attempt', 'severity' => 'high')
        expect(audit_log.metadata.to_s).not_to include('<script>')
      end
    end

    it 'ignoredに更新する' do
      admin = create(:user, :admin)
      event = create(:security_event, resolved_at: Time.current)

      result = described_class.call(security_event: event, status: :ignored, actor: admin, request: nil)

      aggregate_failures do
        expect(result).to be_updated
        expect(event.reload.ignored_at).to be_present
        expect(event.resolved_at).to be_nil
      end
    end

    it '未知statusは更新しない' do
      admin = create(:user, :admin)
      event = create(:security_event)

      result = described_class.call(security_event: event, status: :unknown, actor: admin, request: nil)

      aggregate_failures do
        expect(result).not_to be_updated
        expect(result.error_code).to eq('invalid_status')
        expect(event.reload.resolved_at).to be_nil
        expect(AuditLog).not_to exist(action: 'admin.security_events.unknown')
      end
    end

    it 'AuditLogの保存に失敗した場合はstatus更新をrollbackする' do
      admin = create(:user, :admin)
      resolved_at = 1.hour.ago.change(usec: 0)
      event = create(:security_event, resolved_at: resolved_at, ignored_at: nil)
      allow(AuditLogs).to receive(:record_admin_action!).and_raise(StandardError, 'audit failed')

      expect {
        described_class.call(security_event: event, status: :ignored, actor: admin, request: nil)
      }.to raise_error(StandardError, 'audit failed')

      aggregate_failures do
        expect(event.reload.resolved_at).to eq(resolved_at)
        expect(event.ignored_at).to be_nil
        expect(AuditLog).not_to exist(action: 'admin.security_events.ignored')
      end
    end

    it 'AuditLog validation失敗時はstatus更新をrollbackして失敗Resultを返す' do
      admin = create(:user, :admin)
      event = create(:security_event)
      audit_error = ActiveRecord::RecordInvalid.new(AuditLog.new)
      allow(AuditLogs).to receive(:record_admin_action!).and_raise(audit_error)

      result = described_class.call(security_event: event, status: :resolved, actor: admin, request: nil)

      aggregate_failures do
        expect(result).not_to be_updated
        expect(result.error_code).to eq('record_invalid')
        expect(event.reload.resolved_at).to be_nil
        expect(event.ignored_at).to be_nil
        expect(AuditLog).not_to exist(action: 'admin.security_events.resolved')
      end
    end
  end
end
