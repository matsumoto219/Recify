require 'rails_helper'

RSpec.describe Announcement, type: :model do
  describe 'validations' do
    it 'valid factory' do
      expect(build(:announcement)).to be_valid
    end

    it 'public_idを自動生成し、公開URL向けの形式にする' do
      announcement = create(:announcement)

      aggregate_failures do
        expect(announcement.public_id).to match(/\Aann_[A-Za-z0-9]{16}\z/)
        expect(announcement.to_param).to eq(announcement.public_id)
      end
    end

    it 'public_idの重複を不正にする' do
      existing = create(:announcement)
      duplicate = build(:announcement, public_id: existing.public_id)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:public_id]).to be_present
    end

    it 'public_id生成時に既存値との衝突を避ける' do
      duplicate_random = 'ABCDEFGHJKLMNPQR'
      unique_random = 'STUVWXYZabcdefgh'
      create(:announcement, public_id: "ann_#{duplicate_random}")

      allow(SecureRandom).to receive(:base58).and_return(duplicate_random, unique_random)

      announcement = create(:announcement)

      expect(announcement.public_id).to eq("ann_#{unique_random}")
    end

    it 'public_idのDB unique index衝突時はpublic_idを再生成して保存する' do
      existing = create(:announcement)
      unique_random = 'STUVWXYZabcdefgh'
      announcement = build(:announcement, public_id: existing.public_id)

      allow(SecureRandom).to receive(:base58).and_return(unique_random)

      expect(announcement.save!(validate: false)).to be(true)
      expect(announcement.public_id).to eq("ann_#{unique_random}")
    end

    it 'titleは必須かつ120文字まで' do
      blank = build(:announcement, title: '')
      too_long = build(:announcement, title: 'a' * 121)

      aggregate_failures do
        expect(blank).not_to be_valid
        expect(blank.errors[:title]).to be_present
        expect(too_long).not_to be_valid
        expect(too_long.errors[:title]).to be_present
      end
    end

    it 'bodyは必須かつ2000文字まで' do
      blank = build(:announcement, body: '')
      too_long = build(:announcement, body: 'a' * 2001)

      aggregate_failures do
        expect(blank).not_to be_valid
        expect(blank.errors[:body]).to be_present
        expect(too_long).not_to be_valid
        expect(too_long.errors[:body]).to be_present
      end
    end

    it 'statusはallowlistだけを許可する' do
      valid = build(:announcement, status: 'published')
      invalid = build(:announcement, status: 'unknown')

      aggregate_failures do
        expect(valid).to be_valid
        expect(invalid).not_to be_valid
        expect(invalid.errors[:status]).to be_present
      end
    end

    it 'kindはallowlistだけを許可する' do
      valid = build(:announcement, kind: 'maintenance')
      invalid = build(:announcement, kind: 'unknown')

      aggregate_failures do
        expect(valid).to be_valid
        expect(invalid).not_to be_valid
        expect(invalid.errors[:kind]).to be_present
      end
    end

    it 'priorityは-100から100までの整数にする' do
      low = build(:announcement, priority: -101)
      high = build(:announcement, priority: 101)
      decimal = build(:announcement, priority: 1.5)

      aggregate_failures do
        expect(build(:announcement, priority: -100)).to be_valid
        expect(build(:announcement, priority: 100)).to be_valid
        expect(low).not_to be_valid
        expect(high).not_to be_valid
        expect(decimal).not_to be_valid
      end
    end

    it 'ends_atはstarts_atより後にする' do
      announcement = build(:announcement, starts_at: Time.zone.local(2026, 7, 1, 10), ends_at: Time.zone.local(2026, 7, 1, 9))

      expect(announcement).not_to be_valid
      expect(announcement.errors[:ends_at]).to be_present
    end

    it 'created_by / updated_by は任意にする' do
      announcement = build(:announcement, created_by: nil, updated_by: nil)

      expect(announcement).to be_valid
    end
  end

  describe 'scopes' do
    it 'visible_on_publicは公開中のお知らせだけを返す' do
      current = Time.current
      visible = create(:announcement, :published, starts_at: current - 1.day, ends_at: current + 1.day)
      no_window = create(:announcement, :published, starts_at: nil, ends_at: nil)
      draft = create(:announcement, status: 'draft')
      archived = create(:announcement, status: 'archived')
      scheduled = create(:announcement, :published, starts_at: current + 1.day, ends_at: nil)
      expired = create(:announcement, :published, starts_at: current - 2.days, ends_at: current - 1.day)

      aggregate_failures do
        expect(described_class.visible_on_public(current)).to contain_exactly(visible, no_window)
        expect(described_class.draft).to include(draft)
        expect(described_class.archived).to include(archived)
        expect(described_class.scheduled).to include(scheduled)
        expect(described_class.expired).to include(expired)
      end
    end

    it 'ordered_for_publicはpinned、priority、published_at、created_atの順にする' do
      old = create(:announcement, :published, priority: 1, published_at: 3.days.ago, created_at: 3.days.ago)
      newer = create(:announcement, :published, priority: 1, published_at: 1.day.ago, created_at: 1.day.ago)
      high_priority = create(:announcement, :published, priority: 50, published_at: 4.days.ago, created_at: 4.days.ago)
      pinned = create(:announcement, :published, pinned: true, priority: -1, published_at: 5.days.ago, created_at: 5.days.ago)
      no_published_at = create(:announcement, status: 'published', published_at: nil, created_at: Time.current)

      expect(described_class.ordered_for_public).to eq([ pinned, high_priority, newer, old, no_published_at ])
    end

    it 'ordered_for_adminは作成日の新しい順にする' do
      old = create(:announcement, created_at: 2.days.ago)
      new_record = create(:announcement, created_at: Time.current)

      expect(described_class.ordered_for_admin).to eq([ new_record, old ])
    end
  end
end
