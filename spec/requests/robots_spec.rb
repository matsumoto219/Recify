require 'rails_helper'

RSpec.describe 'Robots policy', type: :request do
  describe 'GET /robots.txt' do
    it '公開入口だけを許可し、private/admin/storage系をクロール対象外にする' do
      get '/robots.txt'

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq('text/plain')
        expect(response.body).to include("User-agent: *\n")
        expect(response.body).to include("Allow: /\n")
        expect(response.body).to include("Disallow: /admin\n")
        expect(response.body).to include("Disallow: /receipts\n")
        expect(response.body).to include("Disallow: /settings\n")
        expect(response.body).to include("Disallow: /notifications\n")
        expect(response.body).to include("Disallow: /users\n")
        expect(response.body).to include("Disallow: /legal/consent\n")
        expect(response.body).to include("Disallow: /up\n")
        expect(response.body).to include("Disallow: /rails/active_storage/\n")
        expect(response.body).to include("Sitemap: /sitemap.xml\n")
        expect(response.body).not_to include('/admin/security_events')
        expect(response.body).not_to include('/admin/system_settings')
      end
    end
  end
end
