# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Browser boundary security', type: :request do
  it 'does not emit permissive CORS headers for arbitrary browser origins' do
    get root_path, headers: { 'Origin' => 'https://attacker.example' }

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(response.headers['Access-Control-Allow-Origin']).to be_blank
      expect(response.headers['Access-Control-Allow-Credentials']).to be_blank
      expect(response.headers['Access-Control-Allow-Headers']).to be_blank
    end
  end

  it 'records suspicious external redirect parameters without redirecting to them' do
    user = create(:user)
    sign_in user

    expect {
      get receipts_path, params: { redirect_to: 'https://attacker.example/phishing' }
    }.to change(SecurityEvent.where(event_type: 'open_redirect_attempt'), :count).by(1)

    event = SecurityEvent.last

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(response).not_to be_redirect
      expect(response.location).to be_blank
      expect(event).to have_attributes(
        actor_user: user,
        field_name: 'redirect_to',
        matched_rule: 'external_redirect_url',
        payload_excerpt: 'https://attacker.example/phishing'
      )
    end
  end
end
