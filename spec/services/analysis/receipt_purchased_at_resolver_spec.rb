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

    it 'does not replace an OCR-supported time with an unsupported AI datetime' do
      result = described_class.call(
        ai_attrs: { purchased_at: '2026-04-19 17:05' },
        candidates: candidates,
        lines: [ '16:41' ],
        profile: profile
      )

      expect(result).to eq(Time.zone.parse('2026-04-19 16:41'))
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

  describe '.resolve' do
    def source_candidate(index, role:, date: '2026-09-01', time: '07:36', association: 'exact')
      {
        candidate_id: "datetime_line_#{index}", source_path: "lines[#{index}]", line_index: index,
        date: date, time: time, precision: time ? 'datetime' : 'date_only',
        role: role, association: association
      }.compact
    end

    def resolve_sources(sources, ai_text: nil, complete: true, truncated: false)
      described_class.resolve(
        ai_attrs: { purchased_at_text: ai_text },
        candidates: {
          purchased_at_text: '2026-09-01 06:08',
          purchased_at_evidence: {
            schema_version: 'purchased_at_evidence_v1', candidates: sources,
            complete: complete, truncated: truncated, omitted_count: truncated ? 1 : 0, invalid: false
          }
        },
        lines: [],
        profile: profile
      )
    end

    it 'selects the settlement event when Azure and AI point to service start' do
      result = resolve_sources([
        source_candidate(0, role: 'service_start', time: '06:08'),
        source_candidate(1, role: 'settlement')
      ], ai_text: '2026-09-01 06:08')

      expect(result).to include(
        value: Time.zone.parse('2026-09-01 07:36'), state: 'confirmed', precision: 'datetime',
        role: 'settlement', candidate_id: 'datetime_line_1', reason_codes: []
      )
    end

    [ [ 'settlement', 'conflicted' ], [ 'unknown', 'uncertain' ] ].each do |role, state|
      it "keeps the purchase date and reports #{state} for competing #{role} clocks without dates" do
        result = resolve_sources([
          source_candidate(0, role: role, time: nil),
          source_candidate(1, role: role, date: nil, time: '12:00').merge(precision: 'time_only'),
          source_candidate(2, role: role, date: nil, time: '13:00').merge(precision: 'time_only')
        ])

        expect(result).to include(
          value: Time.zone.parse('2026-09-01'), state: state, precision: 'date_only',
          reason_codes: [ "purchased_at_#{state}" ]
        )
      end
    end

    it 'keeps settlement ahead of a later receipt issue or service end' do
      result = resolve_sources([
        source_candidate(0, role: 'issuance', time: '07:38'),
        source_candidate(1, role: 'service_end', time: '07:40'),
        source_candidate(2, role: 'settlement')
      ])

      expect(result[:value]).to eq(Time.zone.parse('2026-09-01 07:36'))
      expect(result[:reason_codes]).to be_empty
    end

    it 'keeps a confirmed purchase date without claiming an observed midnight time' do
      result = resolve_sources([ source_candidate(0, role: 'transaction', time: nil) ])

      expect(result).to include(
        value: Time.zone.parse('2026-09-01'), state: 'date_only', precision: 'date_only', reason_codes: []
      )
    end

    it 'distinguishes an explicitly printed midnight from a date-only value' do
      result = resolve_sources([ source_candidate(0, role: 'settlement', time: '00:00') ])

      expect(result).to include(state: 'confirmed', precision: 'datetime', reason_codes: [])
    end

    it 'retains the purchase date with a conflict reason when settlement times disagree' do
      result = resolve_sources([
        source_candidate(0, role: 'settlement'),
        source_candidate(1, role: 'settlement', time: '08:00')
      ], ai_text: '2026-09-01 07:36')

      expect(result).to include(
        value: Time.zone.parse('2026-09-01'), precision: 'date_only', state: 'conflicted',
        reason_codes: [ 'purchased_at_conflicted' ]
      )
    end

    it 'does not choose a purchase date when transaction dates conflict' do
      result = resolve_sources([
        source_candidate(0, role: 'settlement'),
        source_candidate(1, role: 'settlement', date: '2026-09-02')
      ])

      expect(result).to include(value: nil, state: 'conflicted', reason_codes: [ 'purchased_at_conflicted' ])
    end

    it 'does not combine a service-start date with a settlement clock time' do
      partial = source_candidate(1, role: 'settlement').except(:date).merge(precision: 'time_only')
      result = resolve_sources([ source_candidate(0, role: 'service_start', time: nil), partial ])

      expect(result).to include(value: nil, state: 'uncertain', reason_codes: [ 'purchased_at_uncertain' ])
    end

    it 'does not restore rejected entry or duration sources from the legacy OCR value' do
      result = resolve_sources([
        source_candidate(0, role: 'service_start', time: '06:08'),
        source_candidate(1, role: 'duration', time: '01:28')
      ], ai_text: '2026-09-01 06:08')

      expect(result).to include(value: nil, state: 'missing', reason_codes: [ 'purchased_at_missing' ])
    end

    it 'does not treat a remaining settlement as unique after competing evidence was omitted' do
      result = resolve_sources([ source_candidate(0, role: 'settlement') ], complete: false, truncated: true)

      expect(result[:state]).to eq('uncertain')
      expect(result[:reason_codes]).to eq([ 'purchased_at_uncertain' ])
    end

    it 'allows omitted non-purchase detail when the purchase evidence is complete' do
      result = resolve_sources([ source_candidate(0, role: 'settlement') ], truncated: true)

      expect(result).to include(state: 'confirmed', reason_codes: [])
    end

    it 'does not use legacy full timestamps when a saved source was truncated' do
      result = described_class.resolve(
        ai_attrs: { purchased_at_text: '2026-09-01 06:08' },
        candidates: { purchased_at_text: '2026-09-01 06:08' },
        lines: [ '2026-09-01 06:08' ],
        profile: profile,
        source_complete: false
      )

      expect(result[:state]).to eq('uncertain')
      expect(result[:reason_codes]).to eq([ 'purchased_at_uncertain' ])
    end

    it 'does not restore a legacy full timestamp attached to an excluded split label' do
      result = described_class.resolve(
        ai_attrs: { purchased_at_text: '2026-09-01 06:08' },
        candidates: { purchased_at_text: '2026-09-01 06:08' },
        lines: [ '入庫', '06:08' ],
        profile: profile
      )

      expect(result).to include(value: nil, state: 'missing', reason_codes: [ 'purchased_at_missing' ])
    end

    it 'does not relabel an OCR decision as AI-owned merely because the values match' do
      snapshot = described_class.fallback_snapshot(
        ai_attrs: { purchased_at_text: '2026-04-19 16:41' },
        candidates: { purchased_at_text: '2026-04-19 16:41' },
        lines: [ '精算 2026-04-19 16:41' ],
        profile: profile
      )

      expect(snapshot[:source]).to eq('ocr_purchased_at_text')
    end

    it 'does not borrow a date for an unrelated unlabeled clock beside a complete transaction timestamp' do
      unrelated = source_candidate(1, role: 'unknown', time: '12:34', association: 'unlabeled')
        .except(:date).merge(precision: 'time_only')
      result = resolve_sources([ source_candidate(0, role: 'unknown'), unrelated ])

      expect(result).to include(value: Time.zone.parse('2026-09-01 07:36'), state: 'confirmed', reason_codes: [])
    end

    it 'keeps agreeing complete timestamps without claiming that their distinct event identities merged' do
      result = resolve_sources([ source_candidate(0, role: 'unknown'), source_candidate(1, role: 'unknown') ])

      expect(result).to include(value: Time.zone.parse('2026-09-01 07:36'), state: 'confirmed', reason_codes: [])
      expect(result).not_to have_key(:candidate_id)
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
