# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Security::IpAccessSnapshot do
  let(:ip_address) { '8.8.8.8' }

  around do |example|
    original_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.reset!

    example.run
  ensure
    Rack::Attack.reset!
    Rack::Attack.cache.store = original_store
  end

  it 'IP単位の手動制限・自動制限・関連SecurityEventを返す' do
    block = create(:security_ip_block, ip_address: ip_address)
    create(:security_event, ip_address: ip_address, matched_rule: 'fail2ban/scanner_paths', last_seen_at: 30.minutes.ago)
    create(:security_event, ip_address: ip_address, matched_rule: 'fail2ban/scanner_paths', last_seen_at: 20.minutes.ago)
    create(:security_event, ip_address: ip_address, matched_rule: 'auth/sign_in/ip', last_seen_at: 10.minutes.ago)
    Rack::Attack::Fail2Ban.filter("scanner:#{ip_address}", maxretry: 1, findtime: 10.minutes, bantime: 30.minutes) { true }

    snapshot = described_class.call(ip_address: ip_address)

    aggregate_failures do
      expect(snapshot).to include(
        ip_address: ip_address,
        valid: true,
        blockable: true,
        recent_security_events_count: 3
      )
      expect(snapshot.dig(:manual_block, :active)).to be(true)
      expect(snapshot.dig(:manual_block, :block, :id)).to eq(block.id)
      expect(snapshot.dig(:rack_attack, :any_banned)).to be(true)
      expect(snapshot.dig(:rack_attack, :targets, 'scanner')).to be(true)
      expect(snapshot[:matched_rules]).to include(
        { matched_rule: 'fail2ban/scanner_paths', count: 2 },
        { matched_rule: 'auth/sign_in/ip', count: 1 }
      )
    end
  end

  it 'invalid IPはinvalid snapshotを返す' do
    snapshot = described_class.call(ip_address: 'not-an-ip')

    expect(snapshot).to include(valid: false, blockable: false, non_blockable_reason: 'invalid_ip')
  end
end
