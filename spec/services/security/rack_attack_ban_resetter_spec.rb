# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Security::RackAttackBanResetter do
  include ActiveSupport::Testing::TimeHelpers

  let(:ip_address) { '8.8.8.8' }

  around do |example|
    original_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.reset!

    example.run
  ensure
    travel_back
    Rack::Attack.reset!
    Rack::Attack.cache.store = original_store
  end

  it 'scanner banを解除する' do
    ban_scanner!

    result = described_class.call(ip_address: ip_address, target: 'scanner')

    aggregate_failures do
      expect(result).to be_success
      expect(result.reset_targets).to eq([ 'scanner' ])
      expect(Security::RackAttackBanRegistry.banned_states(ip_address).fetch('scanner')).to be(false)
      expect(Security::AdaptiveScannerRestriction.snapshot(ip_address: ip_address)).to include(
        active: false,
        strike_count: 0
      )
      expect(Security::AdaptiveScannerRestriction.record_probe(ip_address: ip_address)).to include(
        active: false,
        strike_count: 1
      )
    end
  end

  it 'all指定で既知の自動banをすべて解除する' do
    ban_scanner!
    ban_admin_probe!
    ban_direct_upload_probe!

    result = described_class.call(ip_address: ip_address, target: 'all')

    expect(result).to be_success
    expect(Security::RackAttackBanRegistry.banned_states(ip_address).values).to all(be(false))
  end

  it '429 throttle counter resetは対象外にする' do
    ban_scanner!

    result = described_class.call(ip_address: ip_address, target: 'all')

    expect(result.reset_targets).to contain_exactly('scanner', 'admin_probe', 'direct_upload_probe')
  end

  it 'invalid targetを拒否する' do
    result = described_class.call(ip_address: ip_address, target: 'requests/ip')

    expect(result).to have_attributes(success: false, error_code: 'rack_attack_target_invalid')
  end

  it 'adaptive resetのpostconditionを確認できない場合は失敗を返す' do
    allow(Security::AdaptiveScannerRestriction).to receive(:reset!).with(ip_address: ip_address).and_return(false)

    result = described_class.call(ip_address: ip_address, target: 'scanner')

    aggregate_failures do
      expect(result).to be_failure
      expect(result.error_code).to eq('rack_attack_reset_failed')
    end
  end

  def ban_scanner!
    3.times do
      Security::AdaptiveScannerRestriction.record_probe(ip_address: ip_address)
      travel 2.seconds
    end
  end

  def ban_admin_probe!
    Rack::Attack::Allow2Ban.filter("admin_probe:#{ip_address}", maxretry: 1, findtime: 10.minutes, bantime: 30.minutes) { true }
  end

  def ban_direct_upload_probe!
    Rack::Attack::Fail2Ban.filter("direct_upload_probe:#{ip_address}", maxretry: 1, findtime: 10.minutes, bantime: 30.minutes) { true }
  end
end
