require 'rails_helper'

RSpec.describe 'Admin IP diagnostics', type: :request do
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

  describe 'GET /admin/security/ip_diagnostics' do
    it '非ログインユーザーには既存404と同じbody/headerを返す' do
      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      get admin_security_ip_diagnostics_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).not_to include('IP診断')
      end
    end

    it '一般ユーザーには既存404と同じbody/headerを返す' do
      user = create(:user)
      sign_in user

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      sign_in user
      get admin_security_ip_diagnostics_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).not_to include('IP診断')
      end
    end

    it 'adminユーザーは診断画面を閲覧できる' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_security_ip_diagnostics_path,
          headers: {
            'CF-Connecting-IP' => '8.8.8.8',
            'CF-Ray' => 'ray-id',
            'X-Forwarded-For' => '8.8.8.8, 172.70.0.1'
          }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('IP診断')
        expect(response.body).to include('request.ip')
        expect(response.body).to include('request.remote_ip')
        expect(response.body).to include('Rack::Attack想定IP')
        expect(response.body).to include('CF-Connecting-IP')
        expect(response.body).to include('X-Forwarded-For')
        expect(response.body).to include('本番公開前の確認事項')
        expect(response.body).to include('Cloudflare proxy配下')
      end
    end

    it '表示のみでDB更新やAuditLog作成を行わない' do
      admin = create(:user, :admin)
      sign_in admin

      expect do
        get admin_security_ip_diagnostics_path
      end.not_to change {
        [
          AuditLog.count,
          SecurityEvent.count,
          SecurityIpBlock.count,
          ContactRequest.count,
          SystemSetting.count,
          User.count
        ]
      }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('IP診断')
      end
    end

    it '管理トップとIP制限一覧から導線を表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_root_path
      dashboard_body = response.body
      get admin_ip_blocks_path
      ip_blocks_body = response.body

      aggregate_failures do
        expect(dashboard_body).to include(admin_security_ip_diagnostics_path)
        expect(dashboard_body).to include('IP診断')
        expect(ip_blocks_body).to include(admin_security_ip_diagnostics_path)
        expect(ip_blocks_body).to include('IP診断')
      end
    end
  end
end
