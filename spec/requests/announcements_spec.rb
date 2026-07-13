require 'rails_helper'

RSpec.describe 'Announcements', type: :request do
  def attach_public_announcement_image(announcement, alt_text: '公開画像の代替テキスト')
    announcement.update!(image_alt_text: alt_text)
    announcement.image.attach(
      io: StringIO.new(File.binread(Rails.root.join('spec/fixtures/files/receipt_sample.jpg'))),
      filename: 'public-announcement.jpg',
      content_type: 'image/jpeg'
    )
  end

  describe 'GET /announcements' do
    it '公開中のお知らせ一覧を表示し、公開対象外は出さない' do
      pinned = create(:announcement, :published, title: '固定のお知らせ', body: '固定本文', pinned: true, priority: -10, published_at: 5.days.ago)
      high_priority = create(:announcement, :published, title: '優先度の高いお知らせ', body: '優先本文', priority: 80, published_at: 4.days.ago)
      newer = create(:announcement, :published, title: '新しいお知らせ', body: "#{'長い本文' * 40}末尾は一覧に出さない", priority: 0, published_at: 1.day.ago)
      older = create(:announcement, :published, title: '古いお知らせ', body: '古い本文', priority: 0, published_at: 3.days.ago)
      draft = create(:announcement, title: '下書きのお知らせ')
      archived = create(:announcement, :archived, title: 'アーカイブ済みのお知らせ')
      scheduled = create(:announcement, :scheduled, title: '予約中のお知らせ')
      expired = create(:announcement, :expired, title: '終了済みのお知らせ')

      get announcements_path

      document = Nokogiri::HTML(response.body)
      public_header = document.at_css('#public-header')
      public_footer = document.at_css('#public-footer')
      titles = document.css('h2 a[href^="/announcements/"]').map { |node| node.text.squish }
      announcement_links = document.css('a[href^="/announcements/"]').map { |link| link['href'] }

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('announcements.index.title'))
        expect(public_header).to be_present
        expect(public_footer).to be_present
        expect(titles).to eq([ pinned.title, high_priority.title, newer.title, older.title ])
        expect(response.body).to include(I18n.t('announcements.index.pinned'))
        expect(response.body).to include('長い本文')
        expect(response.body).not_to include('末尾は一覧に出さない')
        expect(response.body).not_to include(draft.title)
        expect(response.body).not_to include(archived.title)
        expect(response.body).not_to include(scheduled.title)
        expect(response.body).not_to include(expired.title)
        expect(announcement_links).to include(announcement_path(pinned), announcement_path(newer))
        expect(announcement_links).not_to include("/announcements/#{pinned.id}")
        expect(response.body).not_to include('/admin/announcements')
        expect(response.body).not_to include('translation missing')
        expect(response.body).not_to include('href="#"')
      end
    end

    it '10件ずつページングする' do
      announcements = 12.times.map do |index|
        create(
          :announcement,
          :published,
          title: "ページングお知らせ#{index + 1}",
          priority: 0,
          published_at: index.minutes.ago
        )
      end

      get announcements_path
      first_page = Nokogiri::HTML(response.body)

      get announcements_path(page: 2)
      second_page = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(first_page.css('h2 a[href^="/announcements/"]').size).to eq(10)
        expect(second_page.css('h2 a[href^="/announcements/"]').size).to eq(2)
        expect(first_page.text).to include(announcements.first.title)
        expect(first_page.text).not_to include(announcements.last.title)
        expect(second_page.text).to include(announcements.last.title)
        expect(second_page.at_css("a[href='#{announcements_path(page: 1)}']")).to be_present
      end
    end

    it '設定された表示件数でページングする' do
      create(:system_setting, key: 'limits.public_announcements_per_page', value: SystemSettings.stored_value(3))
      announcements = 5.times.map do |index|
        create(
          :announcement,
          :published,
          title: "設定件数お知らせ#{index + 1}",
          priority: 0,
          published_at: index.minutes.ago
        )
      end

      get announcements_path
      first_page = Nokogiri::HTML(response.body)

      get announcements_path(page: 2)
      second_page = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(first_page.css('h2 a[href^="/announcements/"]').size).to eq(3)
        expect(second_page.css('h2 a[href^="/announcements/"]').size).to eq(2)
        expect(first_page.text).to include(announcements.first.title)
        expect(first_page.text).not_to include(announcements.last.title)
        expect(second_page.text).to include(announcements.last.title)
      end
    end

    it 'お知らせがない場合は空状態を表示する' do
      get announcements_path

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('announcements.index.empty_title'))
        expect(response.body).to include(I18n.t('announcements.index.empty_body'))
      end
    end

    it 'title/bodyのHTML文字列をescapeし、ログイン済みでもpublic layoutで表示する' do
      user = create(:user)
      announcement = create(
        :announcement,
        :published,
        title: '<script>alert("title")</script>',
        body: '<script>alert("body")</script>'
      )
      sign_in user

      get announcements_path

      document = Nokogiri::HTML(response.body)
      public_header = document.at_css('#public-header')

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(public_header).to be_present
        expect(public_header.at_css("a[href='#{receipts_path}']")).to be_present
        expect(document.at_css('#desktop-sidebar')).to be_nil
        expect(document.css('script').map(&:text).join).not_to include('alert("title")')
        expect(document.css('script').map(&:text).join).not_to include('alert("body")')
        expect(response.body).to include('&lt;script&gt;alert(&quot;title&quot;)&lt;/script&gt;')
        expect(response.body).to include('&lt;script&gt;alert(&quot;body&quot;)&lt;/script&gt;')
        expect(document.at_css("a[href='#{announcement_path(announcement)}']")).to be_present
        expect(response.body).not_to include('/home_lp.css')
        expect(response.body).not_to include('data-controller="home-reveal"')
      end
    end

    it '添付画像は一覧には表示しない' do
      announcement = create(:announcement, :published, title: '画像付きお知らせ')
      attach_public_announcement_image(announcement)

      get announcements_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(document.at_css("img[alt='公開画像の代替テキスト']")).to be_nil
        expect(response.body).not_to include('public-announcement.jpg')
      end
    end
  end

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

    it '既存データに残るhttp外部リンクは公開画面へ表示しない' do
      announcement = create(:announcement, :published)
      link = create(:announcement_link, announcement: announcement, label: '安全でない外部リンク')
      link.update_columns(url: 'http://example.test/plaintext')

      get announcement_path(announcement)

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('http://example.test/plaintext', '安全でない外部リンク')
      end
    end

    it 'draft / archived / scheduled / expired は404にする' do
      draft = create(:announcement, status: 'draft')
      archived = create(:announcement, status: 'archived')
      scheduled = create(:announcement, :published, starts_at: 1.day.from_now)
      expired = create(:announcement, :published, ends_at: 1.day.ago)
      hidden_announcements = [ draft, archived, scheduled, expired ]

      hidden_announcements.each do |announcement|
        attach_public_announcement_image(announcement, alt_text: "非公開画像#{announcement.public_id}")
      end

      aggregate_failures do
        hidden_announcements.each do |announcement|
          get announcement_path(announcement)

          expect(response).to have_http_status(:not_found)
          expect(response.body).not_to include("非公開画像#{announcement.public_id}")
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

    it '添付画像を詳細ページだけに表示し、download linkや内部情報は出さない' do
      announcement = create(:announcement, :published)
      attach_public_announcement_image(announcement)

      get announcement_path(announcement)

      document = Nokogiri::HTML(response.body)
      image = document.at_css("img[alt='公開画像の代替テキスト']")

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(image).to be_present
        expect(image['loading']).to eq('eager')
        expect(image['class']).to include('hidden')
        expect(image['data-image-load-state-target']).to include('image')
        expect(image['data-action']).to include('load->image-load-state#imageLoaded')
        expect(image['data-action']).to include('error->image-load-state#imageFailed')
        expect(document.at_css("[data-controller~='image-load-state']")).to be_present
        expect(document.at_css("[data-image-load-state-target~='fallback']").text).to include(
          I18n.t('announcements.image.unavailable')
        )
        expect(document.at_css("a[download]")).to be_nil
        expect(document.at_css("a[href*='public-announcement.jpg']")).to be_nil
        expect(response.body).not_to include(announcement.image.blob.key)
        expect(document.text).not_to include(announcement.image.blob.signed_id)
        expect(response.body).not_to include('image/jpeg')
      end
    end

    it '添付画像のalt textをescapeして表示する' do
      announcement = create(:announcement, :published)
      malicious_alt = '<script>alert("image")</script>'
      attach_public_announcement_image(announcement, alt_text: malicious_alt)

      get announcement_path(announcement)

      document = Nokogiri::HTML(response.body)
      image = document.css('img').find { |node| node['alt'] == malicious_alt }

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(image).to be_present
        expect(document.css('script').map(&:text).join).not_to include('alert("image")')
        expect(response.body).to include('&lt;script&gt;alert(&quot;image&quot;)&lt;/script&gt;')
      end
    end
  end
end
