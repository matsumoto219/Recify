require 'rails_helper'

RSpec.describe Admin::IpBlocksQuery do
  describe '.call' do
    it 'created_at desc / id descで返す' do
      older = create(:security_ip_block, ip_address: '8.8.8.8', created_at: 2.hours.ago)
      newer = create(:security_ip_block, ip_address: '1.1.1.1', created_at: 1.hour.ago)

      result = described_class.call

      expect(result.records.map { |record| record[:id] }).to eq([ newer.id, older.id ])
    end

    it 'status active / revoked / expiredで絞り込める' do
      active = create(:security_ip_block, ip_address: '8.8.8.8', expires_at: 1.hour.from_now)
      revoked = create(:security_ip_block, :revoked, ip_address: '1.1.1.1')
      expired = create(:security_ip_block, ip_address: '9.9.9.9', expires_at: 1.hour.ago)

      aggregate_failures do
        expect(described_class.call(status: 'active').records.map { |record| record[:id] }).to eq([ active.id ])
        expect(described_class.call(status: 'revoked').records.map { |record| record[:id] }).to eq([ revoked.id ])
        expect(described_class.call(status: 'expired').records.map { |record| record[:id] }).to eq([ expired.id ])
      end
    end

    it '未知のstatusは無視する' do
      block = create(:security_ip_block, ip_address: '8.8.8.8')

      result = described_class.call(status: 'unknown')

      expect(result.records.map { |record| record[:id] }).to eq([ block.id ])
    end

    it 'IPで絞り込める' do
      matched = create(:security_ip_block, ip_address: '8.8.8.8')
      create(:security_ip_block, ip_address: '1.1.1.1')

      result = described_class.call(ip_address: '8.8.8.8')

      expect(result.records.map { |record| record[:id] }).to eq([ matched.id ])
    end

    it 'invalid IP filterは空結果にする' do
      create(:security_ip_block, ip_address: '8.8.8.8')

      result = described_class.call(ip_address: 'not-an-ip')

      expect(result.records).to be_empty
    end

    it 'created_by_idとsource_security_event_idで絞り込める' do
      admin = create(:user, :admin)
      source = create(:security_event, ip_address: '8.8.8.8')
      matched = create(:security_ip_block, ip_address: '8.8.8.8', created_by: admin, source_security_event: source)
      create(:security_ip_block, ip_address: '1.1.1.1')

      result = described_class.call(created_by_id: admin.id.to_s, source_security_event_id: source.id.to_s)

      expect(result.records.map { |record| record[:id] }).to eq([ matched.id ])
    end

    it '期限と作成日時で絞り込める' do
      matched = create(
        :security_ip_block,
        ip_address: '8.8.8.8',
        expires_at: Time.zone.local(2026, 6, 23, 12, 0, 0),
        created_at: Time.zone.local(2026, 6, 22, 12, 0, 0)
      )
      create(
        :security_ip_block,
        ip_address: '1.1.1.1',
        expires_at: Time.zone.local(2026, 6, 25, 12, 0, 0),
        created_at: Time.zone.local(2026, 6, 20, 12, 0, 0)
      )

      result = described_class.call(
        expires_after: '2026-06-23T00:00',
        expires_before: '2026-06-24T00:00',
        created_from: '2026-06-22T00:00',
        created_to: '2026-06-23T00:00'
      )

      expect(result.records.map { |record| record[:id] }).to eq([ matched.id ])
    end

    it 'recent SecurityEvent countとRack::Attack状態を含める' do
      block = create(:security_ip_block, ip_address: '8.8.8.8')
      create(:security_event, ip_address: '8.8.8.8', last_seen_at: 1.hour.ago)
      create(:security_event, ip_address: '8.8.8.8', last_seen_at: 2.days.ago)

      result = described_class.call(ip_address: '8.8.8.8')
      record = result.records.first

      aggregate_failures do
        expect(record[:id]).to eq(block.id)
        expect(record[:recent_security_events_count]).to eq(1)
        expect(record.dig(:rack_attack, :targets)).to include('scanner' => false, 'admin_probe' => false, 'direct_upload_probe' => false)
      end
    end
  end

  describe '.filter_options' do
    it 'filter optionsを返す' do
      expect(described_class.filter_options[:states]).to eq(%w[active revoked expired])
    end
  end
end
