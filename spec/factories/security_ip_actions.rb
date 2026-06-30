# frozen_string_literal: true

FactoryBot.define do
  factory :security_ip_action do
    ip_address { "8.8.8.8" }
    action_type { "scanner_restriction" }
    source { "rack_attack" }
    status { "active" }
    matched_rule { "fail2ban/scanner_paths" }
    count { 1 }
    first_seen_at { Time.current }
    last_seen_at { Time.current }
    expires_at { 30.minutes.from_now }
    source_security_event { nil }
    security_ip_block { nil }
    actor_user { nil }
    reason { nil }
    metadata { { "source" => "spec" } }
  end
end
