# frozen_string_literal: true

require "rails_helper"

RSpec.describe Security::IpActionRecorder do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse("2026-06-30 12:00:00")) { example.run }
  end

  it "scanner自動制限をIP単位で集約して記録する" do
    request = instance_double(ActionDispatch::Request, remote_ip: "8.8.8.8")
    event = create(:security_event, ip_address: "8.8.8.8", matched_rule: "fail2ban/scanner_paths", count: 10)

    2.times do
      described_class.record_rate_limit(
        request: request,
        matched_rule: "fail2ban/scanner_paths",
        security_event: event,
        metadata: {
          token: "dummy-secret-value",
          active: true,
          tier: 1,
          strike_count: 3,
          duration_seconds: 30.minutes.to_i,
          expires_at: 30.minutes.from_now
        }
      )
    end

    action = SecurityIpAction.last

    aggregate_failures do
      expect(SecurityIpAction.count).to eq(1)
      expect(action).to have_attributes(
        ip_address: IPAddr.new("8.8.8.8"),
        action_type: "scanner_restriction",
        source: "rack_attack",
        status: "active",
        matched_rule: "fail2ban/scanner_paths",
        count: 2,
        source_security_event: event
      )
      expect(action.expires_at).to be_within(1.second).of(30.minutes.from_now)
      expect(action.metadata).to include(
        "active" => true,
        "tier" => 1,
        "strike_count" => 3,
        "duration_seconds" => 30.minutes.to_i
      )
      expect(action.metadata.to_json).not_to include("dummy-secret-value")
    end
  end

  it "全path制限前のscanner probeはobservedとして期限なしで記録する" do
    request = instance_double(ActionDispatch::Request, remote_ip: "8.8.4.4")

    described_class.record_rate_limit(
      request: request,
      matched_rule: "fail2ban/scanner_paths",
      metadata: { active: false, tier: 0, strike_count: 2, duration_seconds: 0 }
    )

    expect(SecurityIpAction.last).to have_attributes(
      action_type: "scanner_restriction",
      status: "observed",
      expires_at: nil
    )
  end

  it "manual/ip_blocksのblocklisted hitは手動制限履歴と重複させない" do
    request = instance_double(ActionDispatch::Request, remote_ip: "8.8.8.8")

    expect {
      described_class.record_rate_limit(request: request, matched_rule: "manual/ip_blocks")
    }.not_to change(SecurityIpAction, :count)
  end

  it "手動IP制限操作を操作ごとの履歴として記録する" do
    actor = create(:user, :admin)
    block = create(:security_ip_block, ip_address: "8.8.8.8", created_by: actor)
    result = Security::ManualIpBlocker::Result.new(success: true, block: block, ip_address: "8.8.8.8")

    described_class.record_operation(
      operation: "manual_ip_block",
      result: result,
      actor: actor,
      reason: "abuse mitigation",
      source_security_event: block.source_security_event
    )

    expect(SecurityIpAction.last).to have_attributes(
      action_type: "manual_ip_block",
      source: "manual_admin",
      status: "active",
      security_ip_block: block,
      actor_user: actor,
      reason: "abuse mitigation"
    )
  end
end
