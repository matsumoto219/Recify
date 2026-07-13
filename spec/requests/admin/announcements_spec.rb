require 'rails_helper'
require 'zlib'

RSpec.describe 'Admin announcements', type: :request do
  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    original_show_detailed_exceptions = Rails.application.env_config['action_dispatch.show_detailed_exceptions']

    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false

    example.run
  ensure
    Array(@announcement_upload_tempfiles).each do |tempfile|
      tempfile.close
      tempfile.unlink
    rescue Errno::ENOENT
      nil
    end
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

  def png_bytes(width:, height:, minimum_byte_size: nil)
    chunk = lambda do |type, data|
      [ data.bytesize ].pack('N') + type + data + [ Zlib.crc32(type + data) ].pack('N')
    end
    header = [ width, height, 8, 2, 0, 0, 0 ].pack('NNCCCCC')
    row = "\x00".b + ("\xFF\xFF\xFF".b * width)
    compressed = Zlib::Deflate.deflate(row * height)

    png = "\x89PNG\r\n\x1A\n".b +
      chunk.call('IHDR'.b, header) +
      chunk.call('IDAT'.b, compressed) +
      chunk.call('IEND'.b, ''.b)
    return png if minimum_byte_size.blank? || png.bytesize >= minimum_byte_size

    png + ("\0".b * (minimum_byte_size - png.bytesize))
  end

  def uint24_le(value)
    [ value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF ].pack('C3')
  end

  def webp_vp8x_bytes(width:, height:)
    payload = "\0\0\0\0".b + uint24_le(width - 1) + uint24_le(height - 1)

    "RIFF".b +
      [ 4 + 8 + payload.bytesize ].pack('V') +
      "WEBP".b +
      "VP8X".b +
      [ payload.bytesize ].pack('V') +
      payload
  end

  def uploaded_file_from_bytes(bytes:, filename:, content_type:)
    @announcement_upload_tempfiles ||= []
    tempfile = Tempfile.new([ File.basename(filename, ".*"), File.extname(filename) ])
    tempfile.binmode
    tempfile.write(bytes)
    tempfile.rewind
    @announcement_upload_tempfiles << tempfile

    Rack::Test::UploadedFile.new(tempfile.path, content_type, true, original_filename: filename)
  end

  def uploaded_fixture(path, content_type)
    Rack::Test::UploadedFile.new(Rails.root.join(path), content_type)
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
      create(:system_setting, key: 'limits.announcement_image_max_file_size_bytes', value: SystemSettings.stored_value(3.megabytes))
      create(:system_setting, key: 'limits.announcement_image_min_dimension_px', value: SystemSettings.stored_value(120))
      create(:system_setting, key: 'limits.announcement_image_max_dimension_px', value: SystemSettings.stored_value(2048))

      get new_admin_announcement_path

      document = Nokogiri::HTML(response.body)
      image_max_size = ActiveSupport::NumberHelper.number_to_human_size(Announcement.image_max_file_size)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('admin.announcements.new.title'))
        expect(document.at_css("input[type='file'][name='announcement[image]']")).to be_present
        expect(document.at_css("input[name='announcement[image_alt_text]']")).to be_present
        expect(document.at_css("input[type='file'][name='announcement[image]']")['accept']).to eq('image/jpeg,image/png,image/webp')
        expect(document.at_css('[data-controller~="attachment-preview"]')).to be_present
        expect(document.at_css('[data-attachment-preview-target~="image"]')['class']).to include('hidden')
        expect(document.at_css('[data-attachment-preview-target~="fallback"]')['class']).not_to include('hidden')
        expect(document.at_css("input[type='file'][name='announcement[image]']")['data-action']).to include('change->attachment-preview#preview')
        expect(document.at_css('[data-attachment-preview-target~="error"]')['class']).to include('hidden')
        expect(document.css("input[name*='announcement_links_attributes']").size).to be >= 3
        expect(response.body).to include(I18n.t('admin.announcements.form.link_fields.title', number: 3))
        expect(response.body).to include(I18n.t('admin.announcements.form.image_policy.format_notice', max_size: image_max_size))
        expect(response.body).to include(I18n.t('admin.announcements.form.image_policy.dimension_notice', min_dimension: 120, max_dimension: 2048))
        expect(response.body).not_to include('translation missing')
      end
    end
  end

  describe 'POST /admin/announcements' do
    it 'priorityの混在文字列を別の整数として保存しない' do
      admin = create(:user, :admin)
      sign_in admin

      expect {
        post admin_announcements_path, params: { announcement: announcement_params(priority: '12abc') }
      }.not_to change(Announcement, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('12abc')
      end
    end
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
        .and change(AuditLog.where(action: 'announcement.create'), :count).by(1)

      announcement = Announcement.order(:created_at).last
      audit_log = AuditLog.find_by!(action: 'announcement.create', target_id: announcement.id)
      audit_json = audit_log.attributes.slice('metadata', 'before_state', 'after_state').to_json

      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(announcement.status).to eq('draft')
        expect(announcement.created_by).to eq(admin)
        expect(announcement.updated_by).to eq(admin)
        expect(announcement.announcement_links.order(:position).pluck(:label)).to eq(%w[お問い合わせ 利用規約 外部])
        expect(audit_log).to have_attributes(
          actor_user: admin,
          action: 'announcement.create',
          target_type: 'Announcement',
          target_id: announcement.id,
          target_uid: announcement.public_id,
          outcome: 'succeeded'
        )
        expect(audit_log.before_state).to eq({})
        expect(audit_log.after_state).to include('status' => 'draft', 'kind' => 'release')
        expect(audit_json).not_to include('公開前の下書き本文です。')
      end
    end

    it 'AuditLogの保存に失敗した場合は作成をrollbackする' do
      admin = create(:user, :admin)
      sign_in admin
      allow(AuditLogs).to receive(:record_admin_action!).and_raise(StandardError, 'audit failed')

      expect {
        expect {
          post admin_announcements_path, params: { announcement: announcement_params }
        }.not_to change(AnnouncementLink, :count)
      }.not_to change(Announcement, :count)

      aggregate_failures do
        expect(response).to have_http_status(:internal_server_error)
        expect(AuditLog).not_to exist(action: 'announcement.create')
      end
    end

    it 'JPEG画像と代替テキストを含む下書きを作成する' do
      admin = create(:user, :admin)
      sign_in admin

      expect {
        post admin_announcements_path,
             params: {
               announcement: announcement_params(
                 image: uploaded_fixture('spec/fixtures/files/receipt_sample.jpg', 'image/jpeg'),
                 image_alt_text: 'リリース告知画像'
               )
             }
      }.not_to change(SecurityEvent.where(event_type: 'invalid_upload'), :count)

      announcement = Announcement.order(:created_at).last

      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(announcement.image).to be_attached
        expect(announcement.image.blob.content_type).to eq('image/jpeg')
        expect(announcement.image_alt_text).to eq('リリース告知画像')
      end
    end

    it 'PNG画像と代替テキストを含む下書きを作成する' do
      admin = create(:user, :admin)
      sign_in admin

      expect {
        post admin_announcements_path,
             params: {
               announcement: announcement_params(
                 image: uploaded_file_from_bytes(
                   bytes: png_bytes(width: 320, height: 180),
                   filename: 'announcement.png',
                   content_type: 'image/png'
                 ),
                 image_alt_text: 'メンテナンス告知画像'
               )
             }
      }.not_to change(SecurityEvent.where(event_type: 'invalid_upload'), :count)

      announcement = Announcement.order(:created_at).last

      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(announcement.image).to be_attached
        expect(announcement.image.blob.content_type).to eq('image/png')
        expect(announcement.image_alt_text).to eq('メンテナンス告知画像')
      end
    end

    it 'WebP画像と代替テキストを含む下書きを作成する' do
      admin = create(:user, :admin)
      sign_in admin

      expect {
        post admin_announcements_path,
             params: {
               announcement: announcement_params(
                 image: uploaded_file_from_bytes(
                   bytes: webp_vp8x_bytes(width: 320, height: 180),
                   filename: 'announcement.webp',
                   content_type: 'image/webp'
                 ),
                 image_alt_text: 'WebP告知画像'
               )
             }
      }.not_to change(SecurityEvent.where(event_type: 'invalid_upload'), :count)

      announcement = Announcement.order(:created_at).last

      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(announcement.image).to be_attached
        expect(announcement.image.blob.content_type).to eq('image/webp')
        expect(announcement.image_alt_text).to eq('WebP告知画像')
      end
    end

    it '画像ありで代替テキストが空ならvalidation errorにする' do
      admin = create(:user, :admin)
      sign_in admin
      invalid_upload_count = SecurityEvent.where(event_type: 'invalid_upload').count

      expect {
        post admin_announcements_path,
             params: {
               announcement: announcement_params(
                 image: uploaded_file_from_bytes(
                   bytes: png_bytes(width: 320, height: 180),
                   filename: 'announcement.png',
                   content_type: 'image/png'
                 ),
                 image_alt_text: ''
               )
             }
      }.not_to change(Announcement, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('admin.announcements.form.errors.title'))
        expect(response.body).to include(I18n.t('activerecord.attributes.announcement.image_alt_text'))
        expect(SecurityEvent.where(event_type: 'invalid_upload').count).to eq(invalid_upload_count)
      end
    end

    it 'SVG画像を拒否する' do
      admin = create(:user, :admin)
      sign_in admin
      announcement_count = Announcement.count

      expect {
        post admin_announcements_path,
             params: {
               announcement: announcement_params(
                 image: uploaded_file_from_bytes(
                   bytes: '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>',
                   filename: 'announcement.svg',
                   content_type: 'image/svg+xml'
                 ),
                 image_alt_text: 'SVG告知画像'
               )
             }
      }.to change(SecurityEvent.where(event_type: 'invalid_upload'), :count).by(1)

      event = SecurityEvent.order(:created_at).last
      aggregate_failures do
        expect(Announcement.count).to eq(announcement_count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.announcement.attributes.image.invalid_content_type'))
        expect(event).to have_attributes(
          actor_user: admin,
          field_name: 'announcement.image',
          matched_rule: 'invalid_content_type'
        )
        expect(event.metadata).to include(
          'field_name' => 'announcement.image',
          'filename' => 'announcement.svg',
          'content_type' => 'image/svg+xml',
          'reason' => 'invalid_content_type',
          'controller' => 'admin/announcements',
          'action' => 'create'
        )
        expect(event.metadata.to_json).not_to include('<svg', 'signed_id', '/rails/active_storage')
      end
    end

    it '画像サイズ上限を超える画像を拒否する' do
      admin = create(:user, :admin)
      sign_in admin
      announcement_count = Announcement.count

      expect {
        post admin_announcements_path,
             params: {
               announcement: announcement_params(
                 image: uploaded_file_from_bytes(
                   bytes: png_bytes(width: 320, height: 180, minimum_byte_size: Announcement.image_max_file_size + 1),
                   filename: 'large-announcement.png',
                   content_type: 'image/png'
                 ),
                 image_alt_text: '大きすぎる告知画像'
               )
             }
      }.to change(SecurityEvent.where(event_type: 'invalid_upload'), :count).by(1)

      event = SecurityEvent.order(:created_at).last
      aggregate_failures do
        expect(Announcement.count).to eq(announcement_count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(
          I18n.t(
            'activerecord.errors.models.announcement.attributes.image.file_too_large',
            max_size: ActiveSupport::NumberHelper.number_to_human_size(Announcement.image_max_file_size)
          )
        )
        expect(event).to have_attributes(
          field_name: 'announcement.image',
          matched_rule: 'file_too_large'
        )
        expect(event.metadata).to include(
          'field_name' => 'announcement.image',
          'filename' => 'large-announcement.png',
          'content_type' => 'image/png',
          'reason' => 'file_too_large'
        )
      end
    end

    it 'text/plain画像アップロードを拒否し、SecurityEventに記録する' do
      admin = create(:user, :admin)
      sign_in admin
      announcement_count = Announcement.count

      expect {
        post admin_announcements_path,
             params: {
               announcement: announcement_params(
                 image: uploaded_file_from_bytes(
                   bytes: 'not an image body marker',
                   filename: 'announcement.txt',
                   content_type: 'text/plain'
                 ),
                 image_alt_text: 'テキスト偽装告知画像'
               )
             }
      }.to change(SecurityEvent.where(event_type: 'invalid_upload'), :count).by(1)

      event = SecurityEvent.order(:created_at).last
      aggregate_failures do
        expect(Announcement.count).to eq(announcement_count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.announcement.attributes.image.invalid_content_type'))
        expect(event).to have_attributes(
          field_name: 'announcement.image',
          matched_rule: 'invalid_content_type'
        )
        expect(event.metadata).to include(
          'field_name' => 'announcement.image',
          'filename' => 'announcement.txt',
          'content_type' => 'text/plain',
          'reason' => 'invalid_content_type'
        )
        expect(event.metadata.to_json).not_to include('not an image body marker')
      end
    end

    it 'JPEGとして送られた偽装画像を拒否する' do
      admin = create(:user, :admin)
      sign_in admin
      announcement_count = Announcement.count

      expect {
        post admin_announcements_path,
             params: {
               announcement: announcement_params(
                 image: uploaded_file_from_bytes(
                   bytes: '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>',
                   filename: 'spoofed-announcement.jpg',
                   content_type: 'image/jpeg'
                 ),
                 image_alt_text: '偽装告知画像'
               )
             }
      }.to change(SecurityEvent.where(event_type: 'invalid_upload'), :count).by(1)

      event = SecurityEvent.order(:created_at).last
      aggregate_failures do
        expect(Announcement.count).to eq(announcement_count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.announcement.attributes.image.invalid_content_type'))
        expect(event).to have_attributes(
          field_name: 'announcement.image',
          matched_rule: 'invalid_content_type'
        )
        expect(event.metadata).to include(
          'field_name' => 'announcement.image',
          'filename' => 'spoofed-announcement.jpg',
          'content_type' => 'image/jpeg',
          'reason' => 'invalid_content_type'
        )
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
      admin = create(
        :user,
        :admin,
        email: 'recify-admin-announcement-long-local-part-version12345678901234567890@example-admin-announcement-long-domain.example.com'
      )
      announcement = create(:announcement, created_by: admin, updated_by: admin, title: '<script>alert(1)</script>', body: "<b>本文</b>\n2行目")
      create(:announcement_link, announcement: announcement, label: '<b>リンク</b>', url: '/contact')
      sign_in admin

      get admin_announcement_path(announcement)
      document = Nokogiri::HTML(response.body)
      creator_email_node = document.css('[data-email-address-display]').find { |node| node['title'] == admin.email }
      creator_metadata_cell = creator_email_node&.ancestors&.find { |node| node.name == 'div' && node['class'].to_s.split.include?('min-w-0') }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(announcement.public_id)
        expect(response.body).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
        expect(response.body).to include('&lt;b&gt;本文&lt;/b&gt;')
        expect(response.body).to include('&lt;b&gt;リンク&lt;/b&gt;')
        expect(response.body).not_to include('<script>alert(1)</script>')
        expect(response.body).not_to include('<b>本文</b>')
        expect(response.body).not_to include('translation missing')
        expect(creator_email_node).to be_present
        expect(creator_email_node.text).to eq(admin.email)
        expect(creator_email_node['class'].split).to include('w-full', 'overflow-hidden')
        expect(creator_metadata_cell['class'].split).to include('min-w-0', 'max-w-full')
      end
    end

    it '添付画像情報を表示し、代替テキストはescapeする' do
      admin = create(:user, :admin)
      announcement = create(:announcement, image_alt_text: '<script>alert(1)</script>')
      announcement.image.attach(
        io: StringIO.new(png_bytes(width: 320, height: 180)),
        filename: 'announcement.png',
        content_type: 'image/png'
      )
      sign_in admin

      get admin_announcement_path(announcement)

      document = Nokogiri::HTML(response.body)
      preview_image = document.at_css("img[data-image-load-state-target~='image']")
      image_controller = preview_image&.ancestors&.find do |node|
        node['data-controller'].to_s.split.include?('image-load-state')
      end
      unavailable_fallback = image_controller&.at_css("[data-image-load-state-target~='fallback']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('admin.announcements.show.sections.image'))
        expect(response.body).to include('announcement.png')
        expect(response.body).to include('image/png')
        expect(response.body).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
        expect(response.body).not_to include('<script>alert(1)</script>')
        expect(response.body).not_to include(announcement.image.blob.key)
        expect(response.body).not_to include('signed_id')
        expect(preview_image).to be_present
        expect(preview_image['class']).to include('hidden')
        expect(preview_image['data-action']).to include('error->image-load-state#imageFailed')
        expect(unavailable_fallback.text).to include(I18n.t('announcements.image.unavailable'))
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

    it '保存済み画像をプレビューし、削除チェックと差し替えプレビューを連動できる' do
      admin = create(:user, :admin)
      draft = create(:announcement, status: 'draft', image_alt_text: '既存画像')
      draft.image.attach(
        io: StringIO.new(png_bytes(width: 320, height: 180)),
        filename: 'announcement-preview.png',
        content_type: 'image/png'
      )
      sign_in admin

      get edit_admin_announcement_path(draft)

      document = Nokogiri::HTML(response.body)
      preview_image = document.at_css('[data-attachment-preview-target~="image"]')
      image_controller = preview_image&.ancestors&.find do |node|
        node['data-controller'].to_s.split.include?('image-load-state')
      end
      empty_fallback = document.at_css('[data-attachment-preview-target~="fallback"]')
      unavailable_fallback = image_controller&.at_css('[data-image-load-state-target~="fallback"]')
      remove_checkbox = document.at_css("input[name='announcement[remove_image]']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(preview_image).to be_present
        expect(preview_image['src']).to include('/rails/active_storage/')
        expect(preview_image['data-persisted-url']).to include('/rails/active_storage/')
        expect(preview_image['class']).to include('hidden')
        expect(preview_image['data-image-load-state-target']).to include('image')
        expect(preview_image['data-action']).to include('error->image-load-state#imageFailed')
        expect(empty_fallback['data-image-load-state-target']).to include('empty')
        expect(empty_fallback['class']).to include('hidden')
        expect(unavailable_fallback.text).to include(I18n.t('announcements.image.unavailable'))
        expect(remove_checkbox['data-action']).to include('change->attachment-preview#toggleRemove')
        expect(remove_checkbox['data-attachment-preview-target']).to include('removeCheckbox')
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

      expect {
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
      }.to change(AuditLog.where(action: 'announcement.update'), :count).by(1)

      announcement.reload
      audit_log = AuditLog.find_by!(action: 'announcement.update', target_id: announcement.id)

      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(announcement.title).to eq('更新後のお知らせ')
        expect(announcement.status).to eq('draft')
        expect(announcement.public_id).to eq(original_public_id)
        expect(announcement.updated_by).to eq(admin)
        expect(announcement.announcement_links.pluck(:label)).to eq([ '新しいリンク' ])
        expect(audit_log.before_state).to include('status' => 'draft')
        expect(audit_log.after_state).to include('status' => 'draft', 'kind' => 'release')
        expect(audit_log.metadata.to_json).not_to include('公開前の下書き本文です。')
      end
    end

    it 'AuditLogの保存に失敗した場合は更新とnested link変更をrollbackする' do
      admin = create(:user, :admin)
      original_updater = create(:user)
      announcement = create(:announcement, status: 'draft', title: '更新前', updated_by: original_updater)
      link = create(:announcement_link, announcement: announcement, label: '更新前リンク', url: '/terms', position: 0)
      sign_in admin
      allow(AuditLogs).to receive(:record_admin_action!).and_raise(StandardError, 'audit failed')

      patch admin_announcement_path(announcement),
            params: {
              announcement: announcement_params(
                title: '更新後',
                announcement_links_attributes: {
                  '0' => { id: link.id.to_s, label: '更新後リンク', url: '/privacy', position: '0' }
                }
              )
            }

      aggregate_failures do
        expect(response).to have_http_status(:internal_server_error)
        expect(announcement.reload).to have_attributes(title: '更新前', status: 'draft', updated_by: original_updater)
        expect(link.reload).to have_attributes(label: '更新前リンク', url: '/terms')
        expect(AuditLog).not_to exist(action: 'announcement.update')
      end
    end

    it 'draft画像を差し替える' do
      admin = create(:user, :admin)
      announcement = create(:announcement, status: 'draft', image_alt_text: '古い画像')
      announcement.image.attach(
        io: StringIO.new(png_bytes(width: 320, height: 180)),
        filename: 'old-announcement.png',
        content_type: 'image/png'
      )
      sign_in admin

      patch admin_announcement_path(announcement),
            params: {
              announcement: announcement_params(
                image: uploaded_fixture('spec/fixtures/files/receipt_sample.jpg', 'image/jpeg'),
                image_alt_text: '新しい画像'
              )
            }

      announcement.reload

      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(announcement.image).to be_attached
        expect(announcement.image.filename.to_s).to eq('receipt_sample.jpg')
        expect(announcement.image.blob.content_type).to eq('image/jpeg')
        expect(announcement.image_alt_text).to eq('新しい画像')
      end
    end

    it 'draft画像を削除し、代替テキストを空にする' do
      admin = create(:user, :admin)
      announcement = create(:announcement, status: 'draft', image_alt_text: '削除する画像')
      announcement.image.attach(
        io: StringIO.new(png_bytes(width: 320, height: 180)),
        filename: 'delete-announcement.png',
        content_type: 'image/png'
      )
      sign_in admin

      expect {
        patch admin_announcement_path(announcement),
              params: {
                announcement: announcement_params(
                  remove_image: '1',
                  image_alt_text: ''
                )
              }
      }.not_to change(SecurityEvent.where(event_type: 'invalid_upload'), :count)

      announcement.reload

      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(announcement.image).not_to be_attached
        expect(announcement.image_alt_text).to be_nil
      end
    end

    it 'validation失敗時はremove_image=1でも既存画像を削除しない' do
      admin = create(:user, :admin)
      announcement = create(:announcement, status: 'draft', image_alt_text: '残す画像')
      announcement.image.attach(
        io: StringIO.new(png_bytes(width: 320, height: 180)),
        filename: 'keep-announcement.png',
        content_type: 'image/png'
      )
      sign_in admin

      expect {
        patch admin_announcement_path(announcement),
              params: {
                announcement: announcement_params(
                  title: '',
                  remove_image: '1',
                  image_alt_text: ''
                )
              }
      }.not_to change(SecurityEvent.where(event_type: 'invalid_upload'), :count)

      announcement.reload

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(announcement.image).to be_attached
        expect(announcement.image_alt_text).to eq('残す画像')
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
        expect(audit_log.metadata).to include(
          'image_attached' => false,
          'image_alt_text_present' => false
        )
        expect(audit_log.metadata).not_to include('image_filename', 'image_content_type', 'image_byte_size')
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

    it '画像付きAnnouncementを公開するとAuditLogに安全な画像概要だけを残す' do
      admin = create(:user, :admin)
      announcement = create(
        :announcement,
        status: 'draft',
        title: '画像付きのお知らせ',
        body: 'body-secret-token-value',
        image_alt_text: '<script>alert("alt-secret")</script>'
      )
      announcement.image.attach(
        io: File.open(Rails.root.join('spec/fixtures/files/receipt_sample.jpg')),
        filename: 'audit-image<script>.jpg',
        content_type: 'image/jpeg'
      )
      blob = announcement.image.blob
      sign_in admin
      stub_fresh_admin_reauthentication

      expect {
        patch publish_admin_announcement_path(announcement)
      }.to change(AuditLog, :count).by(1)

      audit_log = AuditLog.last
      audit_json = audit_log.metadata.to_json

      aggregate_failures do
        expect(audit_log.metadata).to include(
          'image_attached' => true,
          'image_filename' => blob.filename.to_s,
          'image_content_type' => 'image/jpeg',
          'image_byte_size' => blob.byte_size,
          'image_alt_text_present' => true
        )
        expect(audit_json).not_to include(blob.key)
        expect(audit_json).not_to include(blob.signed_id)
        expect(audit_json).not_to include(blob.checksum)
        expect(audit_json).not_to include('/rails/active_storage')
        expect(audit_json).not_to include('body-secret-token-value')
        expect(audit_json).not_to include('<script>alert("alt-secret")</script>')
        expect(audit_json).not_to include('checksum')
        expect(audit_json).not_to include('signed_id')
      end
    end

    it 'AuditLogの保存に失敗した場合は公開をrollbackする' do
      admin = create(:user, :admin)
      original_updater = create(:user)
      announcement = create(:announcement, status: 'draft', published_at: nil, updated_by: original_updater)
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(AuditLogs).to receive(:record_admin_action!).and_raise(StandardError, 'audit failed')

      patch publish_admin_announcement_path(announcement)

      aggregate_failures do
        expect(response).to have_http_status(:internal_server_error)
        expect(announcement.reload).to have_attributes(status: 'draft', published_at: nil, updated_by: original_updater)
        expect(AuditLog).not_to exist(action: 'announcement.publish')
      end
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

    it 'AuditLogの保存に失敗した場合はarchiveをrollbackする' do
      admin = create(:user, :admin)
      original_updater = create(:user)
      announcement = create(:announcement, :published, updated_by: original_updater)
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(AuditLogs).to receive(:record_admin_action!).and_raise(StandardError, 'audit failed')

      patch archive_admin_announcement_path(announcement)

      aggregate_failures do
        expect(response).to have_http_status(:internal_server_error)
        expect(announcement.reload).to have_attributes(status: 'published', updated_by: original_updater)
        expect(AuditLog).not_to exist(action: 'announcement.archive')
      end
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
