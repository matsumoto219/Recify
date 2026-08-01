# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Security::IpAccessRules do
  let(:ip_address) { '8.8.8.8' }
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    cache_store.clear
  end

  it '有効な手動IP制限があればblockedになる' do
    create(:security_ip_block, ip_address: ip_address)

    expect(described_class.blocked?(ip_address)).to be(true)
  end

  it '期限切れの手動IP制限はblockedにしない' do
    create(:security_ip_block, ip_address: ip_address, expires_at: 1.minute.ago)

    expect(described_class.blocked?(ip_address)).to be(false)
  end

  it '制限前の判定結果が残っていても新しい手動IP制限を即時反映する' do
    expect(described_class.blocked?(ip_address)).to be(false)
    create(:security_ip_block, ip_address: ip_address)

    expect(described_class.blocked?(ip_address)).to be(true)
  end

  it '制限中の判定結果が残っていても解除を即時反映する' do
    block = create(:security_ip_block, ip_address: ip_address)
    admin = create(:user, :admin)
    expect(described_class.blocked?(ip_address)).to be(true)
    block.update!(
      status: 'revoked',
      revoked_at: Time.current,
      revoked_by: admin,
      revoked_reason: 'false positive'
    )

    expect(described_class.blocked?(ip_address)).to be(false)
  end

  it 'invalid IPはblockedにしない' do
    expect(described_class.blocked?('not-an-ip')).to be(false)
  end

  it 'DB判定が利用できない場合は既存どおりrequestをfail openにする' do
    allow(SecurityIpBlock).to receive(:currently_effective_for_ip)
      .with(IPAddr.new(ip_address))
      .and_raise(ActiveRecord::NoDatabaseError)

    expect(described_class.blocked?(ip_address)).to be(false)
  end
end
