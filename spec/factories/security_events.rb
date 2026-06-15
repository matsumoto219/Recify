FactoryBot.define do
  factory :security_event do
    event_type { 'suspicious_payload' }
    severity { 'medium' }
    actor_user { nil }
    ip_address { '203.0.113.10' }
    user_agent { 'RSpec Browser' }
    request_id { 'req-security-event' }
    path { '/receipts' }
    add_attribute(:method) { 'POST' }
    field_name { 'q' }
    matched_rule { 'sql_comment' }
    payload_excerpt { '1 OR 1=1 --' }
    payload_sha256 { Digest::SHA256.hexdigest(payload_excerpt) }
    count { 1 }
    first_seen_at { Time.current }
    last_seen_at { Time.current }
    metadata { { 'source' => 'spec' } }
  end
end
