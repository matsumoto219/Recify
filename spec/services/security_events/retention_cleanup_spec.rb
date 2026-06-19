require 'rails_helper'

RSpec.describe SecurityEvents::RetentionCleanup do
  describe '.call' do
    it 'severity別保持期間でdry-run対象を返し、削除しない' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      low = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      medium = create(:security_event, severity: 'medium', last_seen_at: now - 91.days)
      high = create(:security_event, severity: 'high', last_seen_at: now - 181.days)
      critical = create(:security_event, severity: 'critical', last_seen_at: now - 181.days)
      create(:security_event, severity: 'low', last_seen_at: now - 29.days)
      create(:security_event, severity: 'high', last_seen_at: now - 179.days)

      result = described_class.call(dry_run: true, now: now, limit: 100)

      aggregate_failures do
        expect(result[:dry_run]).to eq(true)
        expect(result[:expired_count]).to eq(4)
        expect(result[:deleted_count]).to eq(0)
        expect(result[:sample_event_ids]).to match_array([ low.id, medium.id, high.id, critical.id ])
        expect(result[:retentions]).to eq('critical' => 180, 'high' => 180, 'medium' => 90, 'low' => 30)
        expect(SecurityEvent.where(id: result[:sample_event_ids]).count).to eq(4)
      end
    end

    it 'execute時だけ対象を削除する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      retained = create(:security_event, severity: 'low', last_seen_at: now - 29.days)

      result = described_class.call(dry_run: false, now: now, limit: 100)

      aggregate_failures do
        expect(result[:expired_count]).to eq(1)
        expect(result[:deleted_count]).to eq(1)
        expect(SecurityEvent.exists?(expired.id)).to eq(false)
        expect(SecurityEvent.exists?(retained.id)).to eq(true)
      end
    end

    it 'limitで削除対象数を丸める' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      create_list(:security_event, 3, severity: 'low', last_seen_at: now - 31.days)

      result = described_class.call(dry_run: true, now: now, limit: 2)

      expect(result[:expired_count]).to eq(2)
    end

    it 'SystemSettingsのseverity別保持期間を使う' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      create(:system_setting, key: 'retention.security_events_medium_days', value: SystemSettings.stored_value(45))
      expired = create(:security_event, severity: 'medium', last_seen_at: now - 46.days)
      create(:security_event, severity: 'medium', last_seen_at: now - 44.days)

      result = described_class.call(dry_run: true, now: now, limit: 100)

      aggregate_failures do
        expect(result[:expired_count]).to eq(1)
        expect(result[:sample_event_ids]).to eq([ expired.id ])
        expect(result[:retentions]['medium']).to eq(45)
      end
    end
  end
end
