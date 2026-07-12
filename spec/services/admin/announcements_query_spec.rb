require 'rails_helper'

RSpec.describe Admin::AnnouncementsQuery do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-07-12 12:00:00')) { example.run }
  end

  describe '.call' do
    it '新しい順で管理画面用recordを返す' do
      creator = create(:user, email: 'creator@example.com')
      updater = create(:user, email: 'updater@example.com')
      older = create(:announcement, title: '古いお知らせ', created_at: 2.hours.ago)
      newer = create(
        :announcement,
        title: '新しいお知らせ',
        kind: 'maintenance',
        pinned: true,
        priority: 10,
        created_by: creator,
        updated_by: updater,
        created_at: 1.hour.ago
      )
      create(:announcement_link, announcement: newer, label: '詳細', url: '/contact', position: 0)
      create(:announcement_link, announcement: newer, label: '利用規約', url: '/terms', position: 1)

      result = described_class.call

      aggregate_failures do
        expect(result.records.map { |record| record[:announcement] }).to eq([ newer, older ])
        expect(result.records.first).to include(
          announcement: newer,
          id: newer.id,
          public_id: newer.public_id,
          title: '新しいお知らせ',
          status: 'draft',
          kind: 'maintenance',
          pinned: true,
          priority: 10,
          links_count: 2,
          created_by_email: 'creator@example.com',
          updated_by_email: 'updater@example.com'
        )
        expect(result.limit).to eq(50)
        expect(result.offset).to eq(0)
        expect(result.total_count).to eq(2)
      end
    end

    it 'status / kind / pinned / public_id / titleで絞り込める' do
      target = create(
        :announcement,
        title: 'リリース 100%_ready',
        status: 'draft',
        kind: 'release',
        pinned: true
      )
      other = create(
        :announcement,
        title: 'リリース 100XYready',
        status: 'archived',
        kind: 'general',
        pinned: false
      )

      aggregate_failures do
        expect(described_class.call(status: 'draft').records.map { |record| record[:announcement] }).to eq([ target ])
        expect(described_class.call(kind: 'release').records.map { |record| record[:announcement] }).to eq([ target ])
        expect(described_class.call(pinned: 'true').records.map { |record| record[:announcement] }).to eq([ target ])
        expect(described_class.call(pinned: 'false').records.map { |record| record[:announcement] }).to eq([ other ])
        expect(described_class.call(public_id: " #{target.public_id} ").records.map { |record| record[:announcement] }).to eq([ target ])
        expect(described_class.call(title: '100%_ready').records.map { |record| record[:announcement] }).to eq([ target ])
      end
    end

    it '未知のallowlist filterは無視する' do
      announcements = [ create(:announcement), create(:announcement, :archived) ]

      result = described_class.call(status: 'unknown', kind: 'unknown', pinned: '1')

      expect(result.records.map { |record| record[:announcement] }).to contain_exactly(*announcements)
    end

    it 'starts_at / ends_at / published_atの期間で絞り込み、不正日時は無視する' do
      outside = create(
        :announcement,
        :published,
        starts_at: Time.zone.parse('2026-07-07 09:00:00'),
        ends_at: Time.zone.parse('2026-07-08 18:00:00'),
        published_at: Time.zone.parse('2026-07-07 08:00:00')
      )
      target = create(
        :announcement,
        :published,
        starts_at: Time.zone.parse('2026-07-10 09:00:00'),
        ends_at: Time.zone.parse('2026-07-14 18:00:00'),
        published_at: Time.zone.parse('2026-07-11 08:00:00')
      )
      future = create(
        :announcement,
        :published,
        starts_at: Time.zone.parse('2026-07-13 09:00:00'),
        ends_at: Time.zone.parse('2026-07-16 18:00:00'),
        published_at: Time.zone.parse('2026-07-13 08:00:00')
      )

      result = described_class.call(
        starts_at_from: '2026-07-09 00:00:00',
        starts_at_to: '2026-07-11 23:59:59',
        ends_at_from: '2026-07-13 00:00:00',
        ends_at_to: '2026-07-15 00:00:00',
        published_at_from: '2026-07-10 00:00:00',
        published_at_to: '2026-07-12 00:00:00'
      )
      invalid_result = described_class.call(
        starts_at_from: 'invalid',
        ends_at_to: 'invalid',
        published_at_from: 'invalid'
      )

      aggregate_failures do
        expect(result.records.map { |record| record[:announcement] }).to eq([ target ])
        expect(invalid_result.records.map { |record| record[:announcement] }).to contain_exactly(outside, target, future)
      end
    end

    it 'filter後のtotal_countを保ったままlimit上限とoffsetを適用する' do
      older = create(:announcement, kind: 'release', created_at: 3.hours.ago)
      middle = create(:announcement, kind: 'release', created_at: 2.hours.ago)
      newer = create(:announcement, kind: 'release', created_at: 1.hour.ago)
      create(:announcement, kind: 'general', created_at: 30.minutes.ago)

      page = described_class.call(kind: 'release', limit: 1, offset: 1)
      normalized = described_class.call(kind: 'release', limit: 500, offset: -1)
      defaulted = described_class.call(kind: 'release', limit: 0)

      aggregate_failures do
        expect(page.records.map { |record| record[:announcement] }).to eq([ middle ])
        expect(page.limit).to eq(1)
        expect(page.offset).to eq(1)
        expect(page.total_count).to eq(3)
        expect(normalized.records.map { |record| record[:announcement] }).to eq([ newer, middle, older ])
        expect(normalized.limit).to eq(100)
        expect(normalized.offset).to eq(0)
        expect(defaulted.limit).to eq(50)
      end
    end
  end

  describe '.filter_options' do
    it '管理画面で許可する選択肢を返す' do
      expect(described_class.filter_options).to eq(
        statuses: %w[draft published archived],
        kinds: %w[general release maintenance incident],
        pinned: %w[true false]
      )
    end
  end
end
