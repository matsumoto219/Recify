require 'rails_helper'

RSpec.describe Admin::SecurityEventStatusUpdater do
  describe '.call' do
    it 'resolvedに更新し、AuditLogへpayloadなしで記録する' do
      admin = create(:user, :admin)
      event = create(:security_event, event_type: 'xss_attempt', severity: 'high', payload_excerpt: '<script>alert(1)</script>')

      result = described_class.call(security_event: event, status: :resolved, actor: admin, request: nil)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_updated
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
  end
end
