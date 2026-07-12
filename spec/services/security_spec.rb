require 'rails_helper'

RSpec.describe Security do
  describe 'IP address facade' do
    it 'preserves normalization and blockability policy' do
      aggregate_failures do
        expect(described_class.normalize_ip_address(' 8.8.8.8 ')).to eq('8.8.8.8')
        expect(described_class.normalize_ip_address('invalid')).to be_nil
        expect(described_class.ip_address_blockable?('8.8.8.8')).to eq(true)
        expect(described_class.ip_address_blockable?('127.0.0.1')).to eq(false)
        expect(described_class.ip_address_non_blockable_reason('127.0.0.1')).to eq('loopback_ip')
      end
    end
  end

  describe 'Rack::Attack facade' do
    it 'returns the existing target states and default reset target' do
      allow(Security::RackAttackBanRegistry).to receive(:banned_states).with('8.8.8.8').and_return(
        'scanner' => true,
        'admin_probe' => false,
        'direct_upload_probe' => false
      )

      aggregate_failures do
        expect(described_class.rack_attack_banned_states('8.8.8.8')).to include('scanner' => true)
        expect(described_class.rack_attack_default_target).to eq('all')
      end
    end
  end

  describe '.ip_blocked?' do
    it 'delegates the request hot path to the access rules' do
      allow(Security::IpAccessRules).to receive(:blocked?).with('8.8.8.8').and_return(true)

      expect(described_class.ip_blocked?('8.8.8.8')).to eq(true)
    end
  end
end
