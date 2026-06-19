require 'rails_helper'

RSpec.describe 'Home', type: :request do
  describe 'GET /' do
    it '未ログイン時はhome#indexを表示する' do
      get root_path

      document = Nokogiri::HTML(response.body)
      home_lp = document.at_css('.home-lp[data-controller~="home-reveal"]')
      section_nav = document.at_css('.home-section-nav')
      public_header = document.at_css('#public-header')
      public_footer = document.at_css('#public-footer')
      home_stylesheet = document.at_css("link[rel='stylesheet'][href^='/home_lp.css?v=']")
      sign_up_link = public_header.at_css("a[href='#{new_user_registration_path}']")
      final_cta = document.at_css('[data-home-final-cta]')
      detail_items = I18n.t('home.hero_mock.detail.items')
      feature_items = I18n.t('home.features.items')
      how_it_works_steps = I18n.t('home.how_it_works.steps')
      trust_items = I18n.t('home.trust.items')
      section_ids = %w[
        home-hero
        home-problem
        home-before-after
        home-features
        home-how
        home-trust
        home-final-cta
      ]

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('Home#index')
        expect(response.body).not_to include('Find me in app/views/home/index.html.erb')
        expect(response.body).to include(I18n.t('home.hero.heading_lines').first)
        expect(response.body).to include(I18n.t('home.hero.heading_lines').second)
        expect(response.body).to include(I18n.t('home.problem.title'))
        expect(response.body).to include(I18n.t('home.features.title'))
        expect(response.body).to include(I18n.t('home.how_it_works.title'))
        expect(response.body).to include(I18n.t('home.trust.title'))
        expect(response.body).to include(I18n.t('home.final_cta.heading_lines').first)
        expect(response.body).to include('/home_lp.css?v=')
        expect(home_stylesheet).to be_present
        expect(home_stylesheet['data-turbo-track']).to eq('reload')
        expect(home_lp).to be_present
        expect(home_lp.css('[data-home-reveal-target="item"]').size).to be >= 10
        expect(home_lp.css('[data-home-reveal-target="section"]').map { |node| node['id'] }).to include(*section_ids)
        expect(home_lp.at_css('#home-announcements')).to be_nil
        expect(section_nav).to be_present
        expect(section_nav['aria-label']).to eq(I18n.t('home.section_nav.label'))
        expect(section_nav.css('[data-home-reveal-target="navItem"]')).to be_empty
        section_ids.each do |section_id|
          section = home_lp.at_css("section##{section_id}")

          expect(section).to be_present
          expect(section['data-home-section-label']).to be_present
        end
        expect(home_lp.at_css('.home-hero-heading .sr-only').text.strip).to eq(I18n.t('home.hero.heading_lines').join(' '))
        expect(home_lp.at_css('.home-hero-heading-visual[aria-hidden="true"]')).to be_present
        expect(home_lp.css('[data-home-conditional-break]').size).to eq(4)
        expect(home_lp.css('.home-lp-conditional-break').size).to eq(4)
        expect(home_lp.at_css('.home-hero-mock[data-home-reveal-target~="mock"]')).to be_present
        expect(home_lp.at_css('.home-hero-scan-line')).to be_present
        expect(home_lp.css('.home-hero-line-item').size).to eq(detail_items.size)
        expect(home_lp.css('.home-hero-line-item-marker').size).to eq(detail_items.size)
        expect(home_lp.css('.home-hero-line-item-category').size).to eq(detail_items.size)
        expect(home_lp.css('.home-hero-line-item-value').size).to eq(detail_items.size)
        expect(home_lp.css('.home-hero-status-step').size).to eq(I18n.t('home.hero_mock.status.items').size)
        expect(home_lp.at_css('.home-hero-status-list')).to be_present
        expect(response.body).not_to include('良い精度')
        expect(response.body).not_to include('AI補完（提案）')
        expect(home_lp.at_css('#home-before-after')).to be_present
        expect(response.body).to include(I18n.t('home.before_after.title'))
        expect(response.body).to include(I18n.t('home.before_after.before.title'))
        expect(response.body).to include(I18n.t('home.before_after.after.title'))
        expect(home_lp.css('.home-lp-snap-track').size).to eq(2)
        expect(home_lp.css('#home-features .home-lp-snap-hint span').size).to eq(feature_items.size)
        expect(home_lp.css('#home-trust .home-lp-snap-hint span').size).to eq(trust_items.size)
        expect(home_lp.css('#home-how .home-step-card').size).to eq(how_it_works_steps.size)
        expect(home_lp.css('#home-how .home-step-visual').size).to eq(how_it_works_steps.size)
        expect(home_lp.at_css('#home-how .home-step-upload-mock')).to be_present
        expect(home_lp.at_css('#home-how .home-step-scan-mock')).to be_present
        expect(home_lp.css('#home-how .home-step-result-check').size).to eq(3)
        expect(home_lp.css('#home-how .home-step-result-check.material-symbols-outlined')).to be_empty
        expect(home_lp.at_css('#home-how .home-step-save-mock')).to be_present
        expect(home_lp.at_css('.home-lp-final-cta-card')).to be_present
        expect(response.body).not_to include(I18n.t('home.notice'))
        expect(public_header).to be_present
        expect(public_header.at_css('.brand-logo-full[aria-label="Recify"]')).to be_present
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_present
        expect(sign_up_link).to be_present
        expect(sign_up_link['class']).to include('btn-primary')
        expect(document.at_css("main a[href='#{new_user_session_path}']")).to be_present
        expect(document.at_css("main a[href='#{new_user_registration_path}']")).to be_present
        expect(final_cta).to be_present
        expect(final_cta.at_css("a[href='#{contact_path}']")).to be_present
        expect(public_footer).to be_present
        expect(public_footer.at_css('.brand-logo-compact[aria-label="Recify"]')).to be_present
        expect(public_footer.at_css("a[href='#{contact_path}']")).to be_present
        expect(public_footer.at_css("a[href='#{terms_path}']")).to be_present
        expect(public_footer.at_css("a[href='#{privacy_path}']")).to be_present
        expect(response.body).not_to include('href="#"')
        expect(response.body).not_to include('translation missing')
      end
    end

    it '公開中のお知らせがある場合だけHero直下に最大6件表示する' do
      pinned = create(:announcement, :published, title: '固定のお知らせ', pinned: true, priority: 0, published_at: 6.days.ago)
      pinned.update!(image_alt_text: 'LPには出さない画像')
      pinned.image.attach(
        io: StringIO.new(File.binread(Rails.root.join('spec/fixtures/files/receipt_sample.jpg'))),
        filename: 'lp-announcement.jpg',
        content_type: 'image/jpeg'
      )
      high_priority = create(:announcement, :published, title: '優先度の高いお知らせ', priority: 90, published_at: 5.days.ago)
      middle_priority = create(:announcement, :published, title: '優先度中のお知らせ', priority: 50, published_at: 4.days.ago)
      lower_priority = create(:announcement, :published, title: '優先度低のお知らせ', priority: 40, published_at: 3.days.ago)
      lower_priority_second = create(:announcement, :published, title: '優先度低めのお知らせ', priority: 30, published_at: 2.days.ago)
      lower_priority_third = create(:announcement, :published, title: '優先度さらに低めのお知らせ', priority: 20, published_at: 1.day.ago)
      hidden_by_limit = create(:announcement, :published, title: '7件目のお知らせ', priority: 10, published_at: Time.current)

      get root_path

      document = Nokogiri::HTML(response.body)
      home_lp = document.at_css('.home-lp')
      section = home_lp.at_css('#home-announcements')
      section_order = home_lp.css('section').map { |node| node['id'] }
      titles = section.css('.home-announcement-title').map { |node| node.text.strip }

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(section).to be_present
        expect(section['data-home-section-label']).to eq(I18n.t('home.section_nav.announcements'))
        expect(section_order.index('home-announcements')).to be < section_order.index('home-problem')
        expect(section.css('.home-announcement-row').size).to eq(6)
        expect(titles).to eq([
          pinned.title,
          high_priority.title,
          middle_priority.title,
          lower_priority.title,
          lower_priority_second.title,
          lower_priority_third.title
        ])
        expect(titles).not_to include(hidden_by_limit.title)
        expect(section.at_css("a[href='#{announcement_path(pinned)}']")).to be_present
        expect(section.text).to include(I18n.t('home.announcements.pinned'))
        expect(section.text).to include(I18n.t('announcements.kinds.general'))
        expect(section.at_css("a[href='#{announcements_path}']")).to be_present
        expect(section.text).to include(I18n.t('home.announcements.view_all'))
        expect(section.at_css("img[alt='LPには出さない画像']")).to be_nil
        expect(response.body).not_to include('lp-announcement.jpg')
        expect(response.body).not_to include('translation missing')
      end
    end

    it '公開対象外のお知らせはLPに表示しない' do
      visible = create(:announcement, :published, title: '表示されるお知らせ')
      draft = create(:announcement, title: '下書きのお知らせ')
      archived = create(:announcement, :archived, title: 'アーカイブ済みのお知らせ')
      scheduled = create(:announcement, :scheduled, title: '予約中のお知らせ')
      expired = create(:announcement, :expired, title: '終了済みのお知らせ')

      get root_path

      document = Nokogiri::HTML(response.body)
      section = document.at_css('#home-announcements')

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(section).to be_present
        expect(section.at_css("a[href='#{announcement_path(visible)}']")).to be_present
        expect(response.body).to include(visible.title)
        expect(response.body).not_to include(draft.title)
        expect(response.body).not_to include(archived.title)
        expect(response.body).not_to include(scheduled.title)
        expect(response.body).not_to include(expired.title)
      end
    end

    it 'ログイン済みならレシート一覧へリダイレクトする' do
      user = create(:user)
      sign_in user

      get root_path

      aggregate_failures do
        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(receipts_path)
      end

      follow_redirect!

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(request.path).to eq(receipts_path)
        expect(request.path).not_to eq(root_path)
      end
    end
  end
end
