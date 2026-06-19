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

  def stub_fresh_admin_reauthentication
    allow_any_instance_of(Admin::AnnouncementsController).to receive(:admin_passkey_reauthenticated?).and_return(true)
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

    it '正規の外部リンクURLはopen redirect検知ノイズにしない' do
      admin = create(:user, :admin)
      sign_in admin

      expect {
        post admin_announcements_path,
             params: {
               announcement: announcement_params(
                 announcement_links_attributes: {
                   '0' => { label: '外部', url: 'https://example.com/news', position: '0' },
                   '1' => { label: '', url: '', position: '1' },
                   '2' => { label: '', url: '', position: '2' }
                 }
               )
             }
      }.not_to change(SecurityEvent.where(event_type: 'open_redirect_attempt', matched_rule: 'external_redirect_url'), :count)

      announcement = Announcement.order(:created_at).last

      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(announcement.announcement_links.first).to be_external
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
      announcement_count = Announcement.count

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
      }.to change(SecurityEvent.where(event_type: 'xss_attempt'), :count).by(1)

      aggregate_failures do
        expect(Announcement.count).to eq(announcement_count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('admin.announcements.form.errors.title'))
      end
    end

    it '危険なURL schemeはSecurityEventとして検知し、保存しない' do
      admin = create(:user, :admin)
      sign_in admin

      expect {
        post admin_announcements_path,
             params: {
               announcement: announcement_params(
                 announcement_links_attributes: {
                   '0' => { label: '危険なリンク', url: 'file:///etc/passwd', position: '0' },
                   '1' => { label: '', url: '', position: '1' },
                   '2' => { label: '', url: '', position: '2' }
                 }
               )
             }
      }.to change(SecurityEvent.where(event_type: 'open_redirect_attempt', matched_rule: 'forbidden_url_scheme'), :count).by(1)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(Announcement.find_by(title: 'iOSアプリ リリース予定')).to be_nil
      end
    end

    it '正規外部URLの抑制範囲外にある危険URLはSecurityEventとして検知する' do
      admin = create(:user, :admin)
      sign_in admin

      cases = {
        '//evil.example.com' => 'protocol_relative_url',
        'https://user@example.com' => 'userinfo_url',
        "https://example.com/\npath" => 'control_character_url'
      }

      aggregate_failures do
        cases.each do |url, matched_rule|
          expect {
            post admin_announcements_path,
                 params: {
                   announcement: announcement_params(
                     announcement_links_attributes: {
                       '0' => { label: '危険なリンク', url: url, position: '0' },
                       '1' => { label: '', url: '', position: '1' },
                       '2' => { label: '', url: '', position: '2' }
                     }
                   )
                 }
          }.to change(SecurityEvent.where(event_type: 'open_redirect_attempt', matched_rule: matched_rule), :count).by(1)

          expect(response).to have_http_status(:unprocessable_content)
        end
      end
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

    it '正規の外部リンクURLへの更新はopen redirect検知ノイズにしない' do
      admin = create(:user, :admin)
      announcement = create(:announcement, status: 'draft')
      create(:announcement_link, announcement: announcement, label: '古いリンク', url: '/terms', position: 0)
      sign_in admin

      expect {
        patch admin_announcement_path(announcement),
              params: {
                announcement: announcement_params(
                  announcement_links_attributes: {
                    '0' => {
                      id: announcement.announcement_links.first.id.to_s,
                      label: '外部',
                      url: 'https://example.com/news',
                      position: '0'
                    },
                    '1' => { label: '', url: '', position: '1' },
                    '2' => { label: '', url: '', position: '2' }
                  }
                )
              }
      }.not_to change(SecurityEvent.where(event_type: 'open_redirect_attempt', matched_rule: 'external_redirect_url'), :count)

      expect(announcement.reload.announcement_links.first.url).to eq('https://example.com/news')
    end
  end

  describe 'PATCH /admin/announcements/:id/publish' do
    it '再認証済みadminがdraftを公開し、AuditLogを残す' do
      admin = create(:user, :admin)
      announcement = create(:announcement, status: 'draft', title: '公開するお知らせ')
      create(
        :announcement_link,
        announcement: announcement,
        label: '外部リンク',
        url: 'https://example.com/news?token=secret#fragment',
        position: 0
      )
      sign_in admin
      stub_fresh_admin_reauthentication

      expect {
        patch publish_admin_announcement_path(announcement)
      }.to change(AuditLog, :count).by(1)

      announcement.reload
      audit_log = AuditLog.last
      audit_json = audit_log.attributes.slice('metadata', 'before_state', 'after_state').to_json

      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(announcement.status).to eq('published')
        expect(announcement.published_at).to be_present
        expect(announcement.updated_by).to eq(admin)
        expect(audit_log).to have_attributes(
          actor_user: admin,
          actor_kind: 'admin',
          action: 'announcement.publish',
          target_type: 'Announcement',
          target_id: announcement.id,
          target_uid: announcement.public_id,
          outcome: 'succeeded'
        )
        expect(audit_log.metadata).to include(
          'public_id' => announcement.public_id,
          'title' => '公開するお知らせ',
          'kind' => announcement.kind,
          'pinned' => announcement.pinned,
          'priority' => announcement.priority
        )
        expect(audit_log.metadata.dig('links', 0, 'url')).to eq('https://example.com/news')
        expect(audit_log.before_state).to include('status' => 'draft')
        expect(audit_log.after_state).to include('status' => 'published')
        expect(audit_json).not_to include('token=secret', 'fragment')
      end

      sign_out admin

      get root_path

      expect(response.body).to include('公開するお知らせ')

      get announcement_path(announcement)

      expect(response).to have_http_status(:ok)
    end

    it 'starts_atが未来なら公開後もLPにはまだ表示しない' do
      admin = create(:user, :admin)
      announcement = create(:announcement, status: 'draft', title: '予約中のお知らせ', starts_at: 1.day.from_now)
      sign_in admin
      stub_fresh_admin_reauthentication

      patch publish_admin_announcement_path(announcement)

      announcement.reload
      sign_out admin
      get root_path

      aggregate_failures do
        expect(announcement.status).to eq('published')
        expect(response.body).not_to include('予約中のお知らせ')
      end
    end

    it '未再認証adminは公開できない' do
      admin = create(:user, :admin)
      announcement = create(:announcement, status: 'draft')
      sign_in admin

      expect {
        patch publish_admin_announcement_path(announcement)
      }.not_to change(AuditLog, :count)

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_announcement_path(announcement)))
        expect(announcement.reload.status).to eq('draft')
      end
    end

    it 'non-adminは公開できない' do
      announcement = create(:announcement, status: 'draft')
      sign_in create(:user)

      patch publish_admin_announcement_path(announcement)

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(announcement.reload.status).to eq('draft')
      end
    end

    it 'archivedから直接公開できない' do
      admin = create(:user, :admin)
      announcement = create(:announcement, :archived)
      sign_in admin
      stub_fresh_admin_reauthentication

      expect {
        patch publish_admin_announcement_path(announcement)
      }.not_to change(AuditLog, :count)

      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(flash[:alert]).to eq(I18n.t('admin.announcements.messages.publish_not_allowed'))
        expect(announcement.reload.status).to eq('archived')
      end
    end
  end

  describe 'PATCH /admin/announcements/:id/archive' do
    it '再認証済みadminが公開中のお知らせをアーカイブし、公開面から隠す' do
      admin = create(:user, :admin)
      announcement = create(:announcement, :published, title: '消えるお知らせ')
      sign_in admin
      stub_fresh_admin_reauthentication

      expect {
        patch archive_admin_announcement_path(announcement)
      }.to change(AuditLog, :count).by(1)

      announcement.reload
      audit_log = AuditLog.last

      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(announcement.status).to eq('archived')
        expect(announcement.updated_by).to eq(admin)
        expect(audit_log).to have_attributes(
          actor_user: admin,
          action: 'announcement.archive',
          target_type: 'Announcement',
          target_id: announcement.id,
          target_uid: announcement.public_id,
          outcome: 'succeeded'
        )
        expect(audit_log.before_state).to include('status' => 'published')
        expect(audit_log.after_state).to include('status' => 'archived')
      end

      sign_out admin

      get root_path

      expect(response.body).not_to include('消えるお知らせ')

      get announcement_path(announcement)

      expect(response).to have_http_status(:not_found)
    end

    it 'draftもアーカイブできる' do
      admin = create(:user, :admin)
      announcement = create(:announcement, status: 'draft')
      sign_in admin
      stub_fresh_admin_reauthentication

      patch archive_admin_announcement_path(announcement)

      expect(announcement.reload.status).to eq('archived')
    end

    it '未再認証adminはアーカイブできない' do
      admin = create(:user, :admin)
      announcement = create(:announcement, :published)
      sign_in admin

      expect {
        patch archive_admin_announcement_path(announcement)
      }.not_to change(AuditLog, :count)

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_announcement_path(announcement)))
        expect(announcement.reload.status).to eq('published')
      end
    end
  end
end
