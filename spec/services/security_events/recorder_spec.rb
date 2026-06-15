require 'rails_helper'

RSpec.describe SecurityEvents::Recorder do
  let(:request) do
    instance_double(
      ActionDispatch::Request,
      remote_ip: '203.0.113.25',
      user_agent: 'RSpec Browser',
      request_id: 'req-123',
      path: '/receipts',
      request_method: 'POST',
      env: {}
    )
  end

  it '親入口からsecurity eventを記録できる' do
    event = SecurityEvents.record!(
      event_type: 'sql_injection_attempt',
      severity: 'high',
      request: request,
      field_name: 'q',
      matched_rule: 'sql_comment',
      payload: "' OR 1=1 --"
    )

    expect(event).to be_persisted
    expect(event).to have_attributes(
      event_type: 'sql_injection_attempt',
      severity: 'high',
      ip_address: be_present,
      request_id: 'req-123',
      path: '/receipts',
      method: 'POST',
      field_name: 'q',
      matched_rule: 'sql_comment',
      payload_excerpt: "' OR 1=1 --",
      count: 1
    )
  end

  it 'XSS payloadをexcerptとして保存し、表示側でescapeできる形に留める' do
    event = described_class.call(
      event_type: 'xss_attempt',
      severity: 'high',
      request: request,
      payload: '<script>alert(1)</script>'
    )

    expect(event.payload_excerpt).to eq('<script>alert(1)</script>')
  end

  it 'secretやPIIをpayload excerptからredactする' do
    event = described_class.call(
      event_type: 'suspicious_payload',
      severity: 'medium',
      request: request,
      payload: 'email=user@example.com&password=secret123&Authorization: Bearer abcdefghijklmnopqrstuvwxyz'
    )

    expect(event.payload_excerpt).to include('[REDACTED_EMAIL]')
    expect(event.payload_excerpt).to include('password=[FILTERED]')
    expect(event.payload_excerpt).to include('Authorization: [FILTERED]')
    expect(event.payload_excerpt).not_to include('user@example.com', 'secret123', 'abcdefghijklmnopqrstuvwxyz')
  end

  it 'metadataからsecret風keyを除去する' do
    event = described_class.call(
      event_type: 'suspicious_payload',
      severity: 'medium',
      request: request,
      metadata: {
        safe: 'value',
        token: 'SECRET',
        nested: {
          api_key: 'KEY',
          count: 1
        }
      }
    )

    expect(event.metadata).to eq(
      'safe' => 'value',
      'nested' => { 'count' => 1 }
    )
  end

  it '長いpayloadを切り詰める' do
    event = described_class.call(
      event_type: 'suspicious_payload',
      severity: 'medium',
      request: request,
      payload: ('safe text ' * 120)
    )

    expect(event.payload_excerpt.bytesize).to eq(SecurityEvent::PAYLOAD_EXCERPT_MAX_BYTES)
  end

  it 'binary payloadは保存しない' do
    event = described_class.call(
      event_type: 'suspicious_payload',
      severity: 'medium',
      request: request,
      payload: "abc\x00def"
    )

    expect(event.payload_excerpt).to be_nil
    expect(event.payload_sha256).to be_nil
  end

  it '同一eventは新規作成せずcountを更新する' do
    2.times do
      described_class.call(
        event_type: 'path_traversal_attempt',
        severity: 'high',
        request: request,
        path: '/receipts',
        payload: '../config/master.key'
      )
    end

    expect(SecurityEvent.count).to eq(1)
    expect(SecurityEvent.first.count).to eq(2)
  end

  it 'resolved済みeventは集約せず新規作成する' do
    event = described_class.call(
      event_type: 'path_traversal_attempt',
      severity: 'high',
      request: request,
      payload: '../config/master.key'
    )
    event.update!(resolved_at: Time.current)

    described_class.call(
      event_type: 'path_traversal_attempt',
      severity: 'high',
      request: request,
      payload: '../config/master.key'
    )

    expect(SecurityEvent.count).to eq(2)
  end
end
