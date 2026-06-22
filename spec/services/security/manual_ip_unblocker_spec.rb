# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Security::ManualIpUnblocker do
  let(:admin) { create(:user, :admin) }

  before do
    Rails.cache.clear
  end

  it '手動IP制限をrevokedに更新してcacheを消す' do
    block = create(:security_ip_block, ip_address: '8.8.8.8')
    Security::IpAccessRules.blocked?('8.8.8.8')

    result = described_class.call(
      ip_address: '8.8.8.8',
      reason: 'false positive',
      revoked_by: admin
    )

    aggregate_failures do
      expect(result).to be_success
      expect(block.reload).to have_attributes(
        status: 'revoked',
        revoked_by: admin,
        revoked_reason: 'false positive'
      )
      expect(block.revoked_at).to be_present
      expect(Security::IpAccessRules.blocked?('8.8.8.8')).to be(false)
    end
  end

  it '解除対象がない場合は拒否する' do
    result = described_class.call(
      ip_address: '8.8.8.8',
      reason: 'false positive',
      revoked_by: admin
    )

    expect(result).to have_attributes(success: false, error_code: 'no_active_manual_block')
  end

  it 'reason必須' do
    create(:security_ip_block, ip_address: '8.8.8.8')

    result = described_class.call(
      ip_address: '8.8.8.8',
      reason: ' ',
      revoked_by: admin
    )

    expect(result).to have_attributes(success: false, error_code: 'reason_required')
  end
end
