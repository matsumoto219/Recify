require 'rails_helper'

RSpec.describe 'Health check', type: :request do
  describe 'GET /up' do
    it '公開health checkとして最小情報だけ返す' do
      get rails_health_check_path

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/html")
        expect(response.headers["Cache-Control"]).to include("no-store")
        expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
        expect(response.body.bytesize).to be <= 8.kilobytes
        expect(response.body).to include("Service is available.")
        expect(Nokogiri::HTML(response.body).at_css('meta[name="robots"]')&.[]("content")).to eq("noindex, nofollow")
        expect(response.body).not_to include('SECRET_KEY_BASE')
        expect(response.body).not_to include('RAILS_MASTER_KEY')
        expect(response.body).not_to include('DATABASE_URL')
        expect(response.body).not_to include('RECIFY_DATABASE_PASSWORD')
        expect(response.body).not_to include('ActiveRecord')
        expect(response.body).not_to include('SolidQueue')
        expect(response.body).not_to include('Rails.root')
        expect(response.body).not_to include('stack')
        expect(response.body).not_to include('trace')
      end
    end
  end
end
