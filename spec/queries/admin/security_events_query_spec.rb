require 'rails_helper'

RSpec.describe Admin::SecurityEventsQuery do
  describe '.call' do
    it 'last_seen_at desc / id descで返す' do
      older = create(:security_event, event_type: 'xss_attempt', last_seen_at: 2.hours.ago)
      newer = create(:security_event, event_type: 'sql_injection_attempt', last_seen_at: 1.hour.ago)

      result = described_class.call

      aggregate_failures do
        expect(result).to be_frozen
        expect(result.records.map { |record| record[:id] }).to eq([ newer.id, older.id ])
      end
    end

    it 'event_type, severity, stateで絞り込める' do
      open_event = create(:security_event, event_type: 'xss_attempt', severity: 'high')
      create(:security_event, event_type: 'xss_attempt', severity: 'medium')
      create(:security_event, event_type: 'sql_injection_attempt', severity: 'high')
      create(:security_event, event_type: 'xss_attempt', severity: 'high', resolved_at: Time.current)

      result = described_class.call(event_type: 'xss_attempt', severity: 'high', state: 'open')

      expect(result.records.map { |record| record[:id] }).to eq([ open_event.id ])
    end

    it 'path部分一致とrequest_idで絞り込める' do
      matched = create(:security_event, path: '/receipts/abc', request_id: 'req-1')
      create(:security_event, path: '/settings', request_id: 'req-1')
      create(:security_event, path: '/receipts/abc', request_id: 'req-2')

      result = described_class.call(path: '/receipts', request_id: 'req-1')

      expect(result.records.map { |record| record[:id] }).to eq([ matched.id ])
    end

    it '未知のevent_typeやseverityは無視する' do
      event = create(:security_event, event_type: 'xss_attempt', severity: 'medium')

      result = described_class.call(event_type: 'unknown', severity: 'unknown')

      expect(result.records.map { |record| record[:id] }).to eq([ event.id ])
    end
  end

  describe '.filter_options' do
    it 'filter optionsを返す' do
      options = described_class.filter_options

      expect(options[:event_types]).to include('xss_attempt')
      expect(options[:severities]).to eq(SecurityEvent::SEVERITIES)
      expect(options[:states]).to eq(%w[open resolved ignored])
    end
  end
end
