require 'rails_helper'

RSpec.describe 'SecurityEvents hooks' do
  let(:request) do
    instance_double(
      ActionDispatch::Request,
      remote_ip: '203.0.113.50',
      user_agent: 'RSpec Browser',
      request_id: 'req-hook',
      path: '/users/sign_in',
      request_method: 'POST',
      env: {}
    )
  end

  it 'rate limit発火を集約記録する' do
    2.times do
      SecurityEvents.record_rate_limit!(
        request: request,
        matched_rule: 'auth/sign_in/ip',
        retry_after: 60
      )
    end

    event = SecurityEvent.find_by!(event_type: 'rate_limit_triggered')
    expect(event).to have_attributes(
      matched_rule: 'auth/sign_in/ip',
      count: 2
    )
    expect(event.metadata).to include('retry_after' => 60)
  end

  it 'CSRF failureをtoken値なしで記録する' do
    SecurityEvents.record_csrf_failure!(request: request)

    event = SecurityEvent.find_by!(event_type: 'csrf_failure')

    expect(event).to have_attributes(
      severity: 'high',
      matched_rule: 'invalid_authenticity_token'
    )
    expect(event.metadata.to_s).not_to include('csrf-token')
  end

  it '外部サービス連続失敗をsecurity eventに記録する' do
    detail = ExternalServices.error_detail(
      service: :ocr,
      provider: 'azure',
      provider_message_safe: 'quota exceeded',
      quota_exceeded: true,
      request_id: 'provider-req'
    )

    SecurityEvents.record_external_service_failure!(
      service: :ocr,
      error_code: 'external_service_quota_exceeded',
      detail: detail,
      consecutive_failures: 2
    )

    event = SecurityEvent.find_by!(event_type: 'external_service_repeated_failure')
    expect(event).to have_attributes(
      severity: 'high',
      matched_rule: 'external_service_quota_exceeded',
      payload_excerpt: 'ocr external_service_quota_exceeded quota exceeded'
    )
    expect(event.metadata.dig('detail', 'request_id')).to eq('provider-req')
  end

  it 'admin high risk操作の短時間集中をsecurity eventに記録する' do
    admin = create(:user, :admin)

    SecurityEvents::ADMIN_BURST_THRESHOLD.times do
      AuditLogs.record_admin_action!(
        actor: admin,
        action: 'system_settings.update',
        outcome: 'succeeded',
        request: request
      )
    end

    event = SecurityEvent.find_by!(event_type: 'system_settings_change_burst')
    expect(event).to have_attributes(
      actor_user: admin,
      severity: 'medium',
      matched_rule: "admin_action_count_gte_#{SecurityEvents::ADMIN_BURST_THRESHOLD}"
    )
    expect(event.metadata).to include(
      'action' => 'system_settings.update',
      'count' => SecurityEvents::ADMIN_BURST_THRESHOLD
    )
  end

  it 'UserLimits overrideの短時間集中をsecurity eventに記録しreason payloadを混ぜない' do
    admin = create(:user, :admin)

    SecurityEvents::ADMIN_BURST_THRESHOLD.times do
      AuditLogs.record_admin_action!(
        actor: admin,
        action: 'admin.users.limit_update',
        outcome: 'succeeded',
        reason: '<script>alert(1)</script> token=secret-value',
        request: request
      )
    end

    event = SecurityEvent.find_by!(event_type: 'user_limits_override_burst')

    aggregate_failures do
      expect(event).to have_attributes(
        actor_user: admin,
        severity: 'medium',
        matched_rule: "admin_action_count_gte_#{SecurityEvents::ADMIN_BURST_THRESHOLD}",
        payload_excerpt: 'admin.users.limit_update'
      )
      expect(event.metadata).to include(
        'action' => 'admin.users.limit_update',
        'count' => SecurityEvents::ADMIN_BURST_THRESHOLD
      )
      expect(event.attributes.to_json).not_to include('<script>alert(1)</script>', 'secret-value')
    end
  end

  it 'HIGH risk admin操作の短時間集中をsecurity eventに記録する' do
    admin = create(:user, :admin)

    SecurityEvents::ADMIN_BURST_THRESHOLD.times do
      AuditLogs.record_admin_action!(
        actor: admin,
        action: 'admin.users.lock',
        outcome: 'succeeded',
        reason: 'support lock request',
        request: request
      )
    end

    event = SecurityEvent.find_by!(event_type: 'admin_high_risk_burst')

    expect(event).to have_attributes(
      actor_user: admin,
      severity: 'high',
      matched_rule: "admin_action_count_gte_#{SecurityEvents::ADMIN_BURST_THRESHOLD}",
      payload_excerpt: 'admin.users.lock'
    )
  end
end
