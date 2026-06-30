# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecurityIpAction do
  it "IPとmetadataを正規化して保存する" do
    action = described_class.create!(
      ip_address: "8.8.8.8",
      action_type: "scanner_restriction",
      source: "rack_attack",
      status: "active",
      matched_rule: "fail2ban/scanner_paths",
      first_seen_at: Time.current,
      last_seen_at: Time.current,
      metadata: { token: "dummy-secret-value", retry_after: 60 }
    )

    aggregate_failures do
      expect(action.ip_address.to_s).to eq("8.8.8.8")
      expect(action.metadata.to_json).not_to include("dummy-secret-value")
      expect(action.metadata).to include("retry_after" => 60)
    end
  end

  it "期限切れのactive actionは表示用statusをexpiredにする" do
    action = build(:security_ip_action, status: "active", expires_at: 1.minute.ago)

    expect(action.display_status).to eq("expired")
  end
end
