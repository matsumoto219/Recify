# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SecurityIpBlock do
  describe 'validations' do
    it 'public single IPを保存できる' do
      block = build(:security_ip_block, ip_address: '8.8.8.8')

      expect(block).to be_valid
    end

    it 'blank IPを拒否する' do
      block = build(:security_ip_block, ip_address: '')

      expect(block).not_to be_valid
    end

    it 'invalid IPを拒否する' do
      block = build(:security_ip_block, ip_address: 'not-an-ip')

      expect(block).not_to be_valid
    end

    it 'private / loopback / reserved IPを拒否する' do
      ips = [ '10.0.0.1', '127.0.0.1', '169.254.10.10', '203.0.113.10', '2001:db8::1' ]

      aggregate_failures do
        ips.each do |ip|
          expect(build(:security_ip_block, ip_address: ip)).not_to be_valid
        end
      end
    end

    it 'revoked statusでは解除情報を必須にする' do
      block = build(:security_ip_block, status: 'revoked', revoked_at: nil, revoked_by: nil, revoked_reason: nil)

      expect(block).not_to be_valid
    end
  end
end
