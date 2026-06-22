# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Security::ManualIpBlocker do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, :admin) }
  let(:security_event) { create(:security_event, ip_address: '8.8.8.8') }

  before do
    Rails.cache.clear
  end

  it '期限付きの手動IP制限を作成してcacheを消す' do
    Security::IpAccessRules.blocked?('8.8.8.8')

    result = described_class.call(
      ip_address: '8.8.8.8',
      reason: 'abuse mitigation',
      created_by: admin,
      expires_at: 2.hours.from_now,
      source_security_event: security_event
    )

    aggregate_failures do
      expect(result).to be_success
      expect(result.block).to have_attributes(
        ip_address: IPAddr.new('8.8.8.8'),
        status: 'active',
        reason: 'abuse mitigation',
        created_by: admin,
        source_security_event: security_event
      )
      expect(Security::IpAccessRules.blocked?('8.8.8.8')).to be(true)
    end
  end

  it 'expires_at未指定では24時間の期限付き制限にする' do
    travel_to(Time.zone.parse('2026-06-23 10:00:00')) do
      result = described_class.call(
        ip_address: '8.8.4.4',
        reason: 'temporary mitigation',
        created_by: admin
      )

      expect(result.block.expires_at).to eq(24.hours.from_now)
    end
  end

  it '無期限は明示confirmationなしでは拒否する' do
    result = described_class.call(
      ip_address: '8.8.4.4',
      reason: 'permanent mitigation',
      created_by: admin,
      permanent: true
    )

    expect(result).to have_attributes(success: false, error_code: 'permanent_confirmation_required')
  end

  it 'private / reserved IPを拒否する' do
    result = described_class.call(
      ip_address: '203.0.113.10',
      reason: 'documentation address',
      created_by: admin
    )

    expect(result).to have_attributes(success: false, error_code: 'reserved_ip')
  end

  it '同じIPに現在有効な制限がある場合は拒否する' do
    create(:security_ip_block, ip_address: '8.8.8.8')

    result = described_class.call(
      ip_address: '8.8.8.8',
      reason: 'duplicate',
      created_by: admin
    )

    expect(result).to have_attributes(success: false, error_code: 'already_blocked')
  end

  it 'source SecurityEventとIPが異なる場合は拒否する' do
    result = described_class.call(
      ip_address: '8.8.4.4',
      reason: 'wrong event',
      created_by: admin,
      source_security_event: security_event
    )

    expect(result).to have_attributes(success: false, error_code: 'source_security_event_ip_mismatch')
  end
end
