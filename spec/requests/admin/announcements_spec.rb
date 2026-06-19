require 'rails_helper'

RSpec.describe 'Admin announcements', type: :request do
  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    original_show_detailed_exceptions = Rails.application.env_config['action_dispatch.show_detailed_exceptions']

    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false

    example.run
  ensure
    Rails.application.env_config['action_dispatch.show_exceptions'] = original_show_exceptions
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = original_show_detailed_exceptions
  end

  def comparable_headers
    response.headers.to_h.except('x-request-id', 'x-runtime')
  end

  def announcement_params(overrides = {})
    {
      title: 'iOSアプリ リリース予定',
      body: '公開前の下書き本文です。',
      kind: 'release',
      pinned: '1',
      priority: '10',
      starts_at: '2026-08-01T09:00',
      ends_at: '2026-08-31T18:00',
      announcement_links_attributes: {
        '0' => { label: '詳細', url: '/contact', position: '0' },
        '1' => { label: '', url: '', position: '1' },
        '2' => { label: '', url: '', position: '2' }
      }
    }.deep_merge(overrides)
  end

  describe 'GET /admin/announcements' do
    it '非ログインユーザーには既存404と同じbody/headerを返す' do
      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      get admin_announcements_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.location).to be_nil
        expect(response.body).not_to include(I18n.t('admin.announcements.index.title'))
      end
    end

    it 'non-adminを拒否する' do
      sign_in create(:user)

      get admin_announcements_path

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(I18n.t('admin.announcements.index.title'))
    end

    it 'adminが一覧とnavigationを閲覧できる' do
      admin = create(:user, :admin)
      announcement = create(:announcement, title: '管理画面のお知らせ', kind: 'maintenance', pinned: true)
      create(:announcement_link, announcement: announcement, label: '確認', url: '/terms')
      sign_in admin

      get admin_announcements_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('admin.announcements.index.title'))
        expect(response.body).to include(I18n.t('admin.navigation.announcements'))
        expect(response.body).to include(announcement.public_id)
        expect(response.body).to include('管理画面のお知らせ')
        expect(response.body).to include(I18n.t('announcements.kinds.maintenance'))
        expect(response.body).to include(admin_announcement_path(announcement))
        expect(response.body).not_to include('href="#"')
        expect(response.body).not_to include('translation missing')
      end
    end

    it 'filterとpaginationを適用する' do
      admin = create(:user, :admin)
      target = create(:announcement, title: '検索対象のお知らせ', status: 'draft', kind: 'release', pinned: true)
      create(:announcement, title: '別のお知らせ', status: 'archived', kind: 'general', pinned: false)
      create(:announcement, title: '検索対象の2件目', status: 'draft', kind: 'release', pinned: true)
      sign_in admin

      get admin_announcements_path(
        status: 'draft',
        kind: 'release',
        pinned: 'true',
        title: '検索対象',
        public_id: target.public_id,
        limit: 1
      )

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(target.public_id)
        expect(response.body).to include(target.title)
        expect(response.body).not_to include('別のお知らせ')
      end

      get admin_announcements_path(status: 'draft', kind: 'release', pinned: 'true', title: '検索対象', limit: 1)

      expect(response.body).to include(I18n.t('admin.announcements.index.results.next'))
    end
  end

  describe 'GET /admin/announcements/new' do
    it 'adminが下書き作成画面を閲覧できる' do
      admin = create(:user, :admin)
      sign_in admin

      get new_admin_announcement_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('admin.announcements.new.title'))
        expect(document.css("input[name*='announcement_links_attributes']").size).to be >= 3
        expect(response.body).to include(I18n.t('admin.announcements.form.link_fields.title', number: 3))
        expect(response.body).not_to include('translation missing')
      end
    end
  end

  describe 'POST /admin/announcements' do
    it '下書きとして作成し、最大3件のリンクと作成者を保存する' do
      admin = create(:user, :admin)
      sign_in admin

      expect {
        post admin_announcements_path,
             params: {
               announcement: announcement_params(
                 status: 'published',
                 announcement_links_attributes: {
                   '0' => { label: 'お問い合わせ', url: '/contact', position: '0' },
                   '1' => { label: '利用規約', url: '/terms', position: '1' },
                   '2' => { label: '外部', url: 'https://example.com/news', position: '2' },
                   '3' => { label: '4件目', url: '/privacy', position: '3' }
                 }
               )
             }
      }.to change(Announcement, :count).by(1)
        .and change(AnnouncementLink, :count).by(3)

      announcement = Announcement.order(:created_at).last

      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(announcement.status).to eq('draft')
        expect(announcement.created_by).to eq(admin)
        expect(announcement.updated_by).to eq(admin)
        expect(announcement.announcement_links.order(:position).pluck(:label)).to eq(%w[お問い合わせ 利用規約 外部])
      end
    end

    it '空のリンク行は無視し、draftはLPにもpublic showにも出さない' do
      admin = create(:user, :admin)
      sign_in admin

      post admin_announcements_path,
           params: {
             announcement: announcement_params(
               title: '公開前のお知らせ',
               announcement_links_attributes: {
                 '0' => { label: '', url: '', position: '0' },
                 '1' => { label: '詳細', url: '/contact', position: '1' },
                 '2' => { label: '', url: '', position: '2' }
               }
             )
           }

      announcement = Announcement.find_by!(title: '公開前のお知らせ')

      aggregate_failures do
        expect(announcement.announcement_links.size).to eq(1)
        expect(announcement.announcement_links.first.label).to eq('詳細')
      end

      sign_out admin
      get root_path

      expect(response.body).not_to include('公開前のお知らせ')

      get announcement_path(announcement)

      expect(response).to have_http_status(:not_found)
    end

    it '片方だけ入力したリンク行はvalidation errorにする' do
      admin = create(:user, :admin)
      sign_in admin

      expect {
        post admin_announcements_path,
             params: {
               announcement: announcement_params(
                 announcement_links_attributes: {
                   '0' => { label: 'ラベルのみ', url: '', position: '0' },
                   '1' => { label: '', url: '', position: '1' },
                   '2' => { label: '', url: '', position: '2' }
                 }
               )
             }
      }.not_to change(Announcement, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('admin.announcements.form.errors.title'))
      end
    end

    it '安全でないURLを拒否する' do
      admin = create(:user, :admin)
      sign_in admin

      expect {
        post admin_announcements_path,
             params: {
               announcement: announcement_params(
                 announcement_links_attributes: {
                   '0' => { label: '危険なリンク', url: 'javascript:alert(1)', position: '0' },
                   '1' => { label: '', url: '', position: '1' },
                   '2' => { label: '', url: '', position: '2' }
                 }
               )
             }
      }.not_to change(Announcement, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('admin.announcements.form.errors.title'))
    end
  end

  describe 'GET /admin/announcements/:id' do
    it 'adminが詳細をpublic_idで閲覧でき、HTML文字列はescapeされる' do
      admin = create(:user, :admin)
      announcement = create(:announcement, title: '<script>alert(1)</script>', body: "<b>本文</b>\n2行目")
      create(:announcement_link, announcement: announcement, label: '<b>リンク</b>', url: '/contact')
      sign_in admin

      get admin_announcement_path(announcement)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(announcement.public_id)
        expect(response.body).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
        expect(response.body).to include('&lt;b&gt;本文&lt;/b&gt;')
        expect(response.body).to include('&lt;b&gt;リンク&lt;/b&gt;')
        expect(response.body).not_to include('<script>alert(1)</script>')
        expect(response.body).not_to include('<b>本文</b>')
        expect(response.body).not_to include('translation missing')
      end
    end
  end

  describe 'GET /admin/announcements/:id/edit' do
    it 'draftだけ編集画面を表示する' do
      admin = create(:user, :admin)
      draft = create(:announcement, status: 'draft')
      published = create(:announcement, :published)
      archived = create(:announcement, :archived)
      sign_in admin

      get edit_admin_announcement_path(draft)

      expect(response).to have_http_status(:success)

      aggregate_failures do
        [ published, archived ].each do |announcement|
          get edit_admin_announcement_path(announcement)

          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end

  describe 'PATCH /admin/announcements/:id' do
    it 'draftを更新し、status/public_idは変更しない' do
      admin = create(:user, :admin)
      announcement = create(:announcement, status: 'draft', created_by: create(:user), updated_by: create(:user))
      create(:announcement_link, announcement: announcement, label: '古いリンク', url: '/terms', position: 0)
      original_public_id = announcement.public_id
      sign_in admin

      patch admin_announcement_path(announcement),
            params: {
              announcement: announcement_params(
                title: '更新後のお知らせ',
                status: 'published',
                announcement_links_attributes: {
                  '0' => { id: announcement.announcement_links.first.id.to_s, label: '', url: '', position: '0' },
                  '1' => { label: '新しいリンク', url: '/privacy', position: '1' },
                  '2' => { label: '', url: '', position: '2' }
                }
              )
            }

      announcement.reload

      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(announcement.title).to eq('更新後のお知らせ')
        expect(announcement.status).to eq('draft')
        expect(announcement.public_id).to eq(original_public_id)
        expect(announcement.updated_by).to eq(admin)
        expect(announcement.announcement_links.pluck(:label)).to eq([ '新しいリンク' ])
      end
    end

    it 'published / archived は更新できない' do
      admin = create(:user, :admin)
      published = create(:announcement, :published, title: '公開中')
      archived = create(:announcement, :archived, title: 'アーカイブ')
      sign_in admin

      aggregate_failures do
        [ published, archived ].each do |announcement|
          patch admin_announcement_path(announcement), params: { announcement: { title: '変更' } }

          expect(response).to have_http_status(:not_found)
          expect(announcement.reload.title).not_to eq('変更')
        end
      end
    end
  end
end
