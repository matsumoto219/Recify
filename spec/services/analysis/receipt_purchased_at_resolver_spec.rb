require 'rails_helper'

RSpec.describe Analysis::ReceiptPurchasedAtResolver do
  let(:profile) { ReceiptAnalysisProfiles.default }
  let(:candidates) { { purchased_at_text: '2026-04-19' } }

  describe '.call' do
    it 'combines a date-only candidate with one purchase-context time' do
      result = described_class.call(
        ai_attrs: {},
        candidates: candidates,
        lines: [ '2026年4月19日', '0796 16時41分' ],
        profile: profile
      )

      expect(result).to eq(Time.zone.parse('2026-04-19 16:41'))
    end

    it 'prefers an explicit AI datetime' do
      result = described_class.call(
        ai_attrs: { purchased_at: '2026-04-19 17:05' },
        candidates: candidates,
        lines: [ '16:41' ],
        profile: profile
      )

      expect(result).to eq(Time.zone.parse('2026-04-19 17:05'))
    end

    it 'keeps the date-only value when distinct time candidates exist' do
      result = described_class.call(
        ai_attrs: {},
        candidates: candidates,
        lines: [ '入庫 15時20分', '0796 16時41分' ],
        profile: profile
      )

      expect(result).to eq(Time.zone.parse('2026-04-19'))
    end

    it 'ignores a time found only in an excluded context' do
      result = described_class.call(
        ai_attrs: {},
        candidates: candidates,
        lines: [ '予約 16時41分' ],
        profile: profile
      )

      expect(result).to eq(Time.zone.parse('2026-04-19'))
    end

    it 'returns nil for an invalid date' do
      result = described_class.call(
        ai_attrs: {},
        candidates: { purchased_at_text: 'not-a-date' },
        lines: [],
        profile: profile
      )

      expect(result).to be_nil
    end
  end

  describe '.fallback_snapshot' do
    it 'records the exact time evidence used by the fallback' do
      snapshot = described_class.fallback_snapshot(
        ai_attrs: {},
        candidates: candidates,
        lines: [ '0796 16時41分' ],
        profile: profile
      )

      expect(snapshot).to eq(
        applied: true,
        source: 'ocr_time_candidate',
        date_text: '2026-04-19',
        time_text: '16時41分',
        normalized_time: '16:41',
        ignored_prefix: '0796',
        source_text: '0796 16時41分',
        result: '2026-04-19 16:41'
      )
    end

    it 'reports when no unique time candidate can be used' do
      snapshot = described_class.fallback_snapshot(
        ai_attrs: {},
        candidates: candidates,
        lines: [ '予約 16時41分' ],
        profile: profile
      )

      expect(snapshot).to eq(
        applied: false,
        reason: 'unique_time_candidate_missing',
        date_text: '2026-04-19'
      )
    end
  end
end
