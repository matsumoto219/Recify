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

  it 'cacheをclearできる' do
    Rails.cache.write(described_class.send(:cache_key, ip_address), false, expires_in: 1.minute)
    create(:security_ip_block, ip_address: ip_address)

    expect(described_class.blocked?(ip_address)).to be(false)

    described_class.clear_cache!(ip_address)

    expect(described_class.blocked?(ip_address)).to be(true)
  end

  it 'invalid IPはblockedにしない' do
    expect(described_class.blocked?('not-an-ip')).to be(false)
  end
end
