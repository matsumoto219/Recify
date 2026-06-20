require 'rails_helper'

RSpec.describe 'Health check', type: :request do
  describe 'GET /up' do
    it '公開health checkとして最小情報だけ返す' do
      get rails_health_check_path

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body.bytesize).to be <= 512
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
