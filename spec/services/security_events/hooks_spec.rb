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
    expect(event.metadata).to include('category' => 'rate_limit', 'retry_after' => 60)
  end

  it 'SystemSettingsの最大検知数でrequest params検知を制限する' do
    create(:system_setting, key: 'security_events.max_detections_per_request', value: SystemSettings.stored_value(2))
    params = 5.times.to_h { |index| [ "q#{index}", '<script>alert(1)</script>' ] }

    detections = SecurityEvents.detect(params: params)

    expect(detections.size).to eq(2)
  end

  it 'CSRF failureをtoken値なしで記録する' do
    SecurityEvents.record_csrf_failure!(request: request)

    event = SecurityEvent.find_by!(event_type: 'csrf_failure')

    expect(event).to have_attributes(
      severity: 'high',
      matched_rule: 'invalid_authenticity_token'
    )
    expect(event.metadata).to include('category' => 'auth', 'source' => 'rails_csrf')
    expect(event.metadata.to_s).not_to include('csrf-token')
  end

  it 'invalid uploadを任意field_nameで安全なmetadataだけ記録する' do
    file = instance_double(
      ActionDispatch::Http::UploadedFile,
      original_filename: "<script>avatar</script>\r\n.png",
      content_type: 'image/png',
      size: 1024
    )

    SecurityEvents.record_invalid_upload!(
      request: request,
      actor_user: nil,
      file: file,
      reason: 'invalid_content_type',
      field_name: 'profile.avatar',
      metadata: {
        signed_id: 'signed-id',
        storage_url: '/rails/active_storage/blobs/redirect/signed-id/file.png'
      },
      validation_errors: [
        'invalid content type',
        'image too small',
        'extra 1',
        'extra 2',
        'extra 3',
        'extra 4'
      ]
    )

    event = SecurityEvent.find_by!(event_type: 'invalid_upload')

    aggregate_failures do
      expect(event).to have_attributes(
        field_name: 'profile.avatar',
        matched_rule: 'invalid_content_type',
        payload_excerpt: '<script>avatar</script>\\r\\n.png'
      )
      expect(event.metadata).to include(
        'category' => 'upload',
        'field_name' => 'profile.avatar',
        'filename' => '<script>avatar</script>\\r\\n.png',
        'content_type' => 'image/png',
        'byte_size' => 1024,
        'extension' => '.png',
        'validation_errors' => [
          'invalid content type',
          'image too small',
          'extra 1',
          'extra 2',
          'extra 3'
        ]
      )
      expect(event.metadata.to_json).not_to include('signed-id', '/rails/active_storage')
    end
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
    expect(event.metadata).to include('category' => 'system')
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
      'category' => 'admin',
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
        'category' => 'admin',
        'action' => 'admin.users.limit_update',
        'count' => SecurityEvents::ADMIN_BURST_THRESHOLD
      )
      expect(event.attributes.to_json).not_to include('<script>alert(1)</script>', 'secret-value')
    end
  end

  it 'SystemSettingsのadmin burst閾値で短時間集中を検知する' do
    admin = create(:user, :admin)
    create(:system_setting, key: 'security_events.admin_burst_threshold', value: SystemSettings.stored_value(2))
    create(:system_setting, key: 'security_events.admin_burst_window_minutes', value: SystemSettings.stored_value(30))

    2.times do
      AuditLogs.record_admin_action!(
        actor: admin,
        action: 'admin.users.limit_update',
        outcome: 'succeeded',
        reason: 'support limit update',
        request: request
      )
    end

    event = SecurityEvent.find_by!(event_type: 'user_limits_override_burst')

    aggregate_failures do
      expect(event).to have_attributes(
        matched_rule: 'admin_action_count_gte_2',
        payload_excerpt: 'admin.users.limit_update'
      )
      expect(event.metadata).to include('count' => 2, 'window_seconds' => 30.minutes.to_i)
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
