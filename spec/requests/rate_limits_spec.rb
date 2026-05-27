require 'rails_helper'

RSpec.describe 'Rails rate limits', type: :request do
  let(:rate_limit_store) { ActiveSupport::Cache::MemoryStore.new }
  let(:rate_limit_message) { I18n.t('flash.rate_limit.too_many_requests') }

  around do |example|
    ApplicationController.rate_limit_cache_store = rate_limit_store
    rate_limit_store.clear
    ActionMailer::Base.deliveries.clear

    example.run
  ensure
    rate_limit_store.clear
    ApplicationController.rate_limit_cache_store = nil
    ActionMailer::Base.deliveries.clear
  end

  def remote_addr(ip)
    { 'REMOTE_ADDR' => ip }
  end

  def expect_rate_limited_response
    aggregate_failures do
      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include(rate_limit_message)
    end
  end

  def uploaded_receipt_image
    Rack::Test::UploadedFile.new(
      Rails.root.join('spec/fixtures/files/receipt_sample.jpg'),
      'image/jpeg'
    )
  end

  def rate_limit_cache_keys
    rate_limit_store.instance_variable_get(:@data).keys
  end

  describe 'POST /users/sign_in' do
    it 'normalizes and throttles login attempts by email digest' do
      5.times do
        post user_session_path,
             params: { user: { email: ' Target@Example.com ', password: 'wrong-password' } }

        expect(response).not_to have_http_status(:too_many_requests)
      end

      post user_session_path,
           params: { user: { email: 'target@example.com', password: 'wrong-password' } }

      expect_rate_limited_response
    end

    it 'keeps different login emails in separate buckets' do
      5.times do
        post user_session_path,
             params: { user: { email: 'first@example.com', password: 'wrong-password' } }
      end

      post user_session_path,
           params: { user: { email: 'second@example.com', password: 'wrong-password' } }

      expect(response).not_to have_http_status(:too_many_requests)
    end

    it 'does not place plaintext email addresses in cache keys' do
      post user_session_path,
           params: { user: { email: 'Secret.Person@Example.com', password: 'wrong-password' } }

      keys = rate_limit_cache_keys.join(' ')

      aggregate_failures do
        expect(keys).not_to include('Secret.Person@Example.com')
        expect(keys).not_to include('secret.person@example.com')
        expect(keys).to match(/[a-f0-9]{64}/)
      end
    end

    it 'returns JSON with 429 when a JSON login request exceeds the limit' do
      5.times do
        post user_session_path,
             params: { user: { email: 'json-limit@example.com', password: 'wrong-password' } }
      end

      post user_session_path,
           params: { user: { email: 'json-limit@example.com', password: 'wrong-password' } },
           headers: { 'ACCEPT' => 'application/json' }

      json = JSON.parse(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:too_many_requests)
        expect(response.media_type).to eq('application/json')
        expect(json).to eq('error' => rate_limit_message)
      end
    end
  end

  describe 'POST /users/password' do
    it 'throttles password reset by email digest and does not send mail after the limit' do
      user = create(:user)

      3.times do
        post user_password_path,
             params: { user: { email: user.email } }

        expect(response).not_to have_http_status(:too_many_requests)
      end

      expect(ActionMailer::Base.deliveries.size).to eq(3)

      post user_password_path,
           params: { user: { email: user.email } }

      aggregate_failures do
        expect_rate_limited_response
        expect(ActionMailer::Base.deliveries.size).to eq(3)
      end
    end

    it 'skips email digest throttling for fake guest emails' do
      guest = User.guest!

      4.times do
        post user_password_path,
             params: { user: { email: guest.email } }

        expect(response).not_to have_http_status(:too_many_requests)
      end

      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  describe 'POST /users/confirmation' do
    it 'throttles confirmation resend by email digest and does not send mail after the limit' do
      user = create(:user, :unconfirmed)
      ActionMailer::Base.deliveries.clear

      3.times do
        post user_confirmation_path,
             params: { user: { email: user.email } }

        expect(response).not_to have_http_status(:too_many_requests)
      end

      expect(ActionMailer::Base.deliveries.size).to eq(3)

      post user_confirmation_path,
           params: { user: { email: user.email } }

      aggregate_failures do
        expect_rate_limited_response
        expect(ActionMailer::Base.deliveries.size).to eq(3)
      end
    end
  end

  describe 'POST /users/unlock' do
    it 'throttles unlock resend by email digest and does not send mail after the limit' do
      user = create(:user)
      user.lock_access!(send_instructions: false)

      3.times do
        post user_unlock_path,
             params: { user: { email: user.email } }

        expect(response).not_to have_http_status(:too_many_requests)
      end

      expect(ActionMailer::Base.deliveries.size).to eq(3)

      post user_unlock_path,
           params: { user: { email: user.email } }

      aggregate_failures do
        expect_rate_limited_response
        expect(ActionMailer::Base.deliveries.size).to eq(3)
      end
    end
  end

  describe 'POST /users/passkey_sessions/options' do
    it 'throttles passkey login options by IP' do
      10.times do
        post users_passkey_sessions_options_path,
             as: :json,
             headers: remote_addr('203.0.113.30')

        expect(response).not_to have_http_status(:too_many_requests)
      end

      post users_passkey_sessions_options_path,
           as: :json,
           headers: remote_addr('203.0.113.30')

      expect_rate_limited_response
    end
  end

  describe 'POST /users/passkey_sessions' do
    it 'throttles passkey login assertions by IP' do
      10.times do
        post users_passkey_sessions_path,
             params: { credential: { id: 'missing-challenge' } },
             as: :json,
             headers: remote_addr('203.0.113.31')

        expect(response).not_to have_http_status(:too_many_requests)
      end

      post users_passkey_sessions_path,
           params: { credential: { id: 'missing-challenge' } },
           as: :json,
           headers: remote_addr('203.0.113.31')

      expect_rate_limited_response
    end
  end

  describe 'POST /users/two_factor/passkey/options' do
    it 'throttles passkey step-up options by IP' do
      10.times do
        post users_two_factor_passkey_options_path,
             as: :json,
             headers: remote_addr('203.0.113.32')

        expect(response).not_to have_http_status(:too_many_requests)
      end

      post users_two_factor_passkey_options_path,
           as: :json,
           headers: remote_addr('203.0.113.32')

      expect_rate_limited_response
    end
  end

  describe 'POST /users/two_factor/passkey' do
    it 'throttles passkey step-up assertions by IP' do
      10.times do
        post users_two_factor_passkey_create_path,
             params: { credential: { id: 'missing-challenge' } },
             as: :json,
             headers: remote_addr('203.0.113.33')

        expect(response).not_to have_http_status(:too_many_requests)
      end

      post users_two_factor_passkey_create_path,
           params: { credential: { id: 'missing-challenge' } },
           as: :json,
           headers: remote_addr('203.0.113.33')

      expect_rate_limited_response
    end
  end

  describe 'POST /users/two_factor/totp' do
    it 'throttles TOTP step-up attempts by pending user and IP' do
      5.times do
        post users_two_factor_totp_create_path,
             params: { code: '000000' },
             headers: remote_addr('203.0.113.36')

        expect(response).not_to have_http_status(:too_many_requests)
      end

      post users_two_factor_totp_create_path,
           params: { code: '000000' },
           headers: remote_addr('203.0.113.36')

      expect_rate_limited_response
    end
  end

  describe 'POST /users/two_factor/recovery_code' do
    it 'throttles recovery code step-up attempts by pending user and IP' do
      5.times do
        post users_two_factor_recovery_code_create_path,
             params: { code: 'WRONG-CODE' },
             headers: remote_addr('203.0.113.37')

        expect(response).not_to have_http_status(:too_many_requests)
      end

      post users_two_factor_recovery_code_create_path,
           params: { code: 'WRONG-CODE' },
           headers: remote_addr('203.0.113.37')

      expect_rate_limited_response
    end
  end

  describe 'POST /admin/reauth/passkey/options' do
    it 'throttles admin passkey reauthentication options by IP' do
      admin = create(:user, :admin)
      sign_in admin

      10.times do
        post options_admin_passkey_reauthentication_path,
             as: :json,
             headers: remote_addr('203.0.113.34')

        expect(response).not_to have_http_status(:too_many_requests)
      end

      post options_admin_passkey_reauthentication_path,
           as: :json,
           headers: remote_addr('203.0.113.34')

      expect_rate_limited_response
    end
  end

  describe 'POST /admin/reauth/passkey' do
    it 'throttles admin passkey reauthentication assertions by IP' do
      admin = create(:user, :admin)
      sign_in admin

      10.times do
        post admin_passkey_reauthentication_path,
             params: { credential: { id: 'missing-challenge' } },
             as: :json,
             headers: remote_addr('203.0.113.35')

        expect(response).not_to have_http_status(:too_many_requests)
      end

      post admin_passkey_reauthentication_path,
           params: { credential: { id: 'missing-challenge' } },
           as: :json,
           headers: remote_addr('203.0.113.35')

      expect_rate_limited_response
    end
  end

  describe 'PATCH /users update_context=guest_registration' do
    it 'throttles guest registration by user and IP and does not update after the limit' do
      guest = User.guest!
      sign_in guest

      3.times do |index|
        patch user_registration_path,
              params: {
                update_context: 'guest_registration',
                user: {
                  email: "guest-limited-#{index}@example.com",
                  password: 'password123',
                  password_confirmation: 'password123',
                  legal_agreement: '1'
                }
              },
              headers: remote_addr('203.0.113.21')

        expect(response).not_to have_http_status(:too_many_requests)
      end

      guest.reload
      previous_email = guest.unconfirmed_email
      previous_deliveries = ActionMailer::Base.deliveries.size

      patch user_registration_path,
            params: {
              update_context: 'guest_registration',
              user: {
                email: 'guest-limited-blocked@example.com',
                password: 'password123',
                password_confirmation: 'password123',
                legal_agreement: '1'
              }
            },
            headers: remote_addr('203.0.113.21')

      aggregate_failures do
        expect_rate_limited_response
        expect(guest.reload.unconfirmed_email).to eq(previous_email)
        expect(ActionMailer::Base.deliveries.size).to eq(previous_deliveries)
      end
    end

    it 'keeps guest registration buckets separate by user' do
      first_guest = User.guest!
      second_guest = User.guest!
      sign_in first_guest

      3.times do |index|
        patch user_registration_path,
              params: {
                update_context: 'guest_registration',
                user: {
                  email: "first-guest-#{index}@example.com",
                  password: 'password123',
                  password_confirmation: 'password123',
                  legal_agreement: '1'
                }
              },
              headers: remote_addr('203.0.113.22')
      end

      sign_out first_guest
      sign_in second_guest

      patch user_registration_path,
            params: {
              update_context: 'guest_registration',
              user: {
                email: 'second-guest@example.com',
                password: 'password123',
                password_confirmation: 'password123',
                legal_agreement: '1'
              }
            },
            headers: remote_addr('203.0.113.22')

      expect(response).not_to have_http_status(:too_many_requests)
    end
  end

  describe 'PATCH /users update_context=email' do
    it 'throttles email changes by user and IP and does not update after the limit' do
      user = create(:user)
      sign_in user

      3.times do |index|
        patch user_registration_path,
              params: {
                update_context: 'email',
                user: {
                  email: "email-limited-#{index}@example.com",
                  current_password: 'password'
                }
              },
              headers: remote_addr('203.0.113.23')

        expect(response).not_to have_http_status(:too_many_requests)
      end

      user.reload
      previous_email = user.email
      previous_unconfirmed_email = user.unconfirmed_email
      previous_deliveries = ActionMailer::Base.deliveries.size

      patch user_registration_path,
            params: {
              update_context: 'email',
              user: {
                email: 'email-limited-blocked@example.com',
                current_password: 'password'
              }
            },
            headers: remote_addr('203.0.113.23')

      aggregate_failures do
        expect_rate_limited_response
        expect(user.reload.email).to eq(previous_email)
        expect(user.unconfirmed_email).to eq(previous_unconfirmed_email)
        expect(ActionMailer::Base.deliveries.size).to eq(previous_deliveries)
      end
    end
  end

  describe 'POST /receipts/upload' do
    it 'throttles receipt upload by user and does not create receipts after the limit' do
      user = create(:user)
      sign_in user
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptOcrJob).to receive(:perform_later)

      10.times do
        post upload_receipts_path,
             params: { receipt: { image: uploaded_receipt_image } }

        expect(response).not_to have_http_status(:too_many_requests)
      end

      aggregate_failures do
        expect(ReceiptOcrJob).to have_received(:perform_later).exactly(10).times
      end

      expect do
        post upload_receipts_path,
             params: { receipt: { image: uploaded_receipt_image } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect_rate_limited_response
        expect(ReceiptOcrJob).to have_received(:perform_later).exactly(10).times
      end
    end
  end
end
