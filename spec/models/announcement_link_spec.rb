require 'rails_helper'

RSpec.describe AnnouncementLink, type: :model do
  describe 'validations' do
    it 'valid factory' do
      expect(build(:announcement_link)).to be_valid
    end

    it 'announcementに属する' do
      link = create(:announcement_link)

      expect(link.announcement).to be_present
    end

    it 'labelは必須かつ80文字まで' do
      blank = build(:announcement_link, label: '')
      too_long = build(:announcement_link, label: 'a' * 81)

      aggregate_failures do
        expect(blank).not_to be_valid
        expect(blank.errors[:label]).to be_present
        expect(too_long).not_to be_valid
        expect(too_long.errors[:label]).to be_present
      end
    end

    it 'urlは必須かつ2048文字まで' do
      blank = build(:announcement_link, url: '')
      too_long = build(:announcement_link, url: "https://example.com/#{'a' * 2048}")

      aggregate_failures do
        expect(blank).not_to be_valid
        expect(blank.errors[:url]).to be_present
        expect(too_long).not_to be_valid
        expect(too_long.errors[:url]).to be_present
      end
    end

    it 'http / https / 内部pathを許可する' do
      allowed_urls = [
        'http://example.com',
        'https://example.com/path',
        '/contact',
        '/terms',
        '/privacy',
        '/announcements/ann_ABCDEFGHJKLMNPQR'
      ]

      aggregate_failures do
        allowed_urls.each do |url|
          expect(build(:announcement_link, url: url)).to be_valid
        end
      end
    end

    it '危険なschemeや曖昧なURLを拒否する' do
      rejected_urls = [
        'javascript:alert(1)',
        'data:text/html,<script>alert(1)</script>',
        'file:///etc/passwd',
        'vbscript:msgbox(1)',
        '//evil.example.com',
        '///evil.example.com',
        'https://user:pass@example.com',
        'http://user@example.com',
        "https://example.com/\npath",
        "https://example.com/\u0000path",
        'contact',
        '../admin',
        '/\evil'
      ]

      aggregate_failures do
        rejected_urls.each do |url|
          link = build(:announcement_link, url: url)
          expect(link).not_to be_valid
          expect(link.errors[:url]).to be_present
        end
      end
    end

    it 'externalはhttp/https absolute URLならtrue、内部pathならfalseにする' do
      external_link = build(:announcement_link, url: 'https://example.com')
      internal_link = build(:announcement_link, url: '/contact')

      external_link.valid?
      internal_link.valid?

      aggregate_failures do
        expect(external_link.external).to be(true)
        expect(internal_link.external).to be(false)
      end
    end

    it 'positionは0以上の整数にする' do
      negative = build(:announcement_link, position: -1)
      decimal = build(:announcement_link, position: 1.5)

      aggregate_failures do
        expect(build(:announcement_link, position: 0)).to be_valid
        expect(negative).not_to be_valid
        expect(decimal).not_to be_valid
      end
    end

    it '1つのお知らせに設定できるリンクは最大3件にする' do
      announcement = create(:announcement)
      create_list(:announcement_link, 3, announcement: announcement)
      fourth = build(:announcement_link, announcement: announcement)

      expect(fourth).not_to be_valid
      expect(fourth.errors[:base]).to be_present
    end
  end
end
