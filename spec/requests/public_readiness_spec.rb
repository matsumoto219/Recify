require 'rails_helper'

RSpec.describe 'Public readiness', type: :request do
  before do
    LegalDocuments::Sync.call
  end

  PUBLIC_ENTRYPOINTS = [
    [ :root_path, 'GET /' ],
    [ :terms_path, 'GET /terms' ],
    [ :privacy_path, 'GET /privacy' ],
    [ :contact_path, 'GET /contact' ],
    [ :announcements_path, 'GET /announcements' ]
  ].freeze

  def path_for(helper_name)
    public_send(helper_name)
  end

  def expect_public_shell_without_private_links(path)
    get path

    document = Nokogiri::HTML(response.body)

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(document.at_css('main')).to be_present
      expect(response.body).not_to include('translation missing')
      expect(response.body).not_to include('id="desktop-sidebar"')
      expect(response.body).not_to include('/admin')
      expect(response.body).not_to include('/admin/security_events')
      expect(response.body).not_to include('/admin/system_settings')
      expect(response.body).not_to include('Rails.root')
      expect(response.body).not_to include('SECRET_KEY_BASE')
      expect(response.body).not_to include('RAILS_MASTER_KEY')
      expect(response.body).not_to include('DATABASE_URL')
    end
  end

  PUBLIC_ENTRYPOINTS.each do |helper_name, label|
    it "#{label} を未ログインの公開入口として表示する" do
      expect_public_shell_without_private_links(path_for(helper_name))
    end
  end

  it 'ログイン済みでもお知らせ一覧はdashboard shellではなくpublic layoutで表示する' do
    sign_in create(:user)

    get announcements_path

    document = Nokogiri::HTML(response.body)

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(document.at_css('#public-header')).to be_present
      expect(document.at_css('#desktop-sidebar')).to be_nil
      expect(response.body).not_to include('/admin')
      expect(response.body).not_to include('translation missing')
    end
  end

  it 'login_restricted中でもhealth checkは公開smoke用に軽量応答する' do
    create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))

    get rails_health_check_path

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(response.body.bytesize).to be <= 512
    end
  end
end
