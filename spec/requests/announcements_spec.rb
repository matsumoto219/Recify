require 'rails_helper'

RSpec.describe 'Announcements', type: :request do
  describe 'GET /announcements/:public_id' do
    it '公開中のお知らせをpublic_idで表示する' do
      announcement = create(
        :announcement,
        :published,
        title: 'iOSアプリ リリース予定',
        body: "1行目\n2行目",
        kind: 'release',
        pinned: true,
        starts_at: 1.day.ago,
        ends_at: 1.day.from_now
      )
      external_link = create(:announcement_link, announcement:, label: '外部サイト', url: 'https://example.com/news', position: 2)
      internal_link = create(:announcement_link, announcement:, label: 'お問い合わせ', url: '/contact', position: 1)

      get announcement_path(announcement)

      document = Nokogiri::HTML(response.body)
      public_header = document.at_css('#public-header')
      public_footer = document.at_css('#public-footer')
      links = document.css('#announcement-links-title + ul a .truncate')

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('iOSアプリ リリース予定')
        expect(response.body).to include('1行目')
        expect(response.body).to include('2行目')
        expect(response.body).to include(I18n.t('announcements.kinds.release'))
        expect(response.body).to include(I18n.t('announcements.show.pinned'))
        expect(response.body).to include(I18n.t('announcements.show.published_at', datetime: I18n.l(announcement.published_at, format: :long)))
        expect(response.body).to include(I18n.t('announcements.show.back_to_home'))
        expect(public_header).to be_present
        expect(public_footer).to be_present
        expect(public_footer.at_css("a[href='#{contact_path}']")).to be_present
        expect(links.map(&:text).map(&:squish)).to eq([ internal_link.label, external_link.label ])
        expect(response.body).not_to include('/home_lp.css')
        expect(response.body).not_to include('data-controller="home-reveal"')
        expect(response.body).not_to include('translation missing')
      end
    end

    it 'draft / archived / scheduled / expired は404にする' do
      draft = create(:announcement, status: 'draft')
      archived = create(:announcement, status: 'archived')
      scheduled = create(:announcement, :published, starts_at: 1.day.from_now)
      expired = create(:announcement, :published, ends_at: 1.day.ago)

      aggregate_failures do
        [ draft, archived, scheduled, expired ].each do |announcement|
          get announcement_path(announcement)

          expect(response).to have_http_status(:not_found)
        end
      end
    end

    it '内部IDでは表示しない' do
      announcement = create(:announcement, :published)

      get "/announcements/#{announcement.id}"

      expect(response).to have_http_status(:not_found)
    end

    it '本文のHTML文字列をタグとして解釈しない' do
      announcement = create(
        :announcement,
        :published,
        title: '<strong>重要</strong>',
        body: "<script>alert('x')</script>\n<b>bold</b>"
      )

      get announcement_path(announcement)

      document = Nokogiri::HTML(response.body)
      body_container = document.at_css('[data-announcement-body]')

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(body_container['class']).to include('whitespace-pre-wrap')
        expect(body_container['class']).to include('break-words')
        expect(body_container['class']).to include('[overflow-wrap:anywhere]')
        expect(body_container.at_css('script')).to be_nil
        expect(body_container.at_css('b')).to be_nil
        expect(response.body).to include('&lt;script&gt;alert')
        expect(response.body).to include('&lt;b&gt;bold&lt;/b&gt;')
      end
    end

    it '外部リンクは別タブ用属性を付け、内部リンクは同一タブにする' do
      announcement = create(:announcement, :published)
      external_link = create(:announcement_link, announcement:, label: '外部', url: 'https://example.com', position: 1)
      internal_link = create(:announcement_link, announcement:, label: '内部', url: '/terms', position: 2)

      get announcement_path(announcement)

      document = Nokogiri::HTML(response.body)
      external_anchor = document.at_css("a[href='#{external_link.url}']")
      internal_anchor = document.at_css("a[href='#{internal_link.url}']")

      aggregate_failures do
        expect(external_anchor).to be_present
        expect(external_anchor['target']).to eq('_blank')
        expect(external_anchor['rel']).to include('noopener')
        expect(external_anchor['rel']).to include('noreferrer')
        expect(internal_anchor).to be_present
        expect(internal_anchor['target']).to be_nil
        expect(internal_anchor['rel']).to be_nil
      end
    end
  end
end
