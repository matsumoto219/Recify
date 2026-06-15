require 'rails_helper'

RSpec.describe 'Contact requests', type: :request do
  let(:rate_limit_store) { ActiveSupport::Cache::MemoryStore.new }

  around do |example|
    ApplicationController.rate_limit_cache_store = rate_limit_store
    rate_limit_store.clear

    example.run
  ensure
    rate_limit_store.clear
    ApplicationController.rate_limit_cache_store = nil
  end

  def valid_contact_params(overrides = {})
    {
      email: 'sender@example.com',
      sender_name: '送信 太郎',
      category: 'account',
      subject: '問い合わせ件名',
      body: '問い合わせ本文です。',
      company_name: ''
    }.merge(overrides)
  end

  def post_contact(params: valid_contact_params, ip: '203.0.113.10')
    post contact_path, params: { contact_request: params }, headers: { 'REMOTE_ADDR' => ip }
  end

  def enable_login_restricted_maintenance(title: '臨時メンテナンス', body: "1行目\n2行目")
    create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))
    create(:system_setting, key: 'maintenance.title', value: SystemSettings.stored_value(title))
    create(:system_setting, key: 'maintenance.body', value: SystemSettings.stored_value(body))
  end

  def with_turnstile_env(enabled:, site_key:, secret_key:)
    original_enabled = ENV["TURNSTILE_ENABLED"]
    original_site_key = ENV["TURNSTILE_SITE_KEY"]
    original_secret_key = ENV["TURNSTILE_SECRET_KEY"]

    ENV["TURNSTILE_ENABLED"] = enabled.to_s
    ENV["TURNSTILE_SITE_KEY"] = site_key
    ENV["TURNSTILE_SECRET_KEY"] = secret_key

    yield
  ensure
    ENV["TURNSTILE_ENABLED"] = original_enabled
    ENV["TURNSTILE_SITE_KEY"] = original_site_key
    ENV["TURNSTILE_SECRET_KEY"] = original_secret_key
  end

  describe 'GET /contact' do
    it '問い合わせフォームと個人情報を必要範囲に絞る注意文を表示する' do
      get contact_path

      document = Nokogiri::HTML(response.body)
      safety_text = document.at_css('.token-bg-warning-soft').text
      email_input = document.at_css("input[type='email'][name='contact_request[email]']")
      category_select = document.at_css("select[name='contact_request[category]']")
      category_first_option = category_select.at_css('option:first-child')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('contact_requests.new.title'))
        expect(category_first_option['value']).to eq('')
        expect(category_first_option.text).to eq(I18n.t('contact_requests.placeholders.category'))
        expect(email_input['placeholder']).to eq(I18n.t('contact_requests.placeholders.email'))
        expect(category_select.at_css("option[value='other'][selected]")).to be_nil
        expect(safety_text).to include('安全のため、必要な範囲の情報のみ入力してください。')
        expect(safety_text).to include('個人情報')
        expect(safety_text).to include('パスワード')
        expect(safety_text).to include('認証コード')
        expect(safety_text).to include('リカバリーコード')
        expect(safety_text).to include('クレジットカード番号')
        expect(safety_text).to include('レシート内容など個人情報を含む場合は、必要な範囲に絞って記載してください。')
        expect(safety_text).not_to include('recovery code', 'TOTP secret', 'cookie', 'session')
        expect(response.body).not_to include('TODO', '未実装')
      end
    end

    it 'Turnstile有効時はwidgetを表示し、secretはHTMLへ出さない' do
      with_turnstile_env(enabled: true, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        get contact_path
      end

      document = Nokogiri::HTML(response.body)
      turnstile_widget = document.at_css('.cf-turnstile')

      aggregate_failures do
        expect(turnstile_widget['data-controller']).to eq('turnstile')
        expect(turnstile_widget['data-turnstile-site-key-value']).to eq('test_site_key')
        expect(document.at_css("script[src*='turnstile']")).to be_nil
        expect(response.body).not_to include('test_secret_key')
      end
    end

    it 'Turnstile無効時はwidgetを表示しない' do
      with_turnstile_env(enabled: false, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        get contact_path
      end

      expect(response.body).not_to include('cf-turnstile')
    end

    it 'login_restricted中は問い合わせ画面にメンテナンスメッセージを表示しHTMLをescapeする' do
      enable_login_restricted_maintenance(
        title: '<strong>臨時メンテナンス</strong>',
        body: "<script>alert('x')</script>\n再開までお待ちください。"
      )

      get contact_path
      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.text).to include('<strong>臨時メンテナンス</strong>')
        expect(document.text).to include("<script>alert('x')</script>")
        expect(document.text).to include('再開までお待ちください。')
        expect(response.body).not_to include('<strong>臨時メンテナンス</strong>')
        expect(response.body).not_to include("<script>alert('x')</script>")
      end
    end

    it 'logged-in userには返信先emailを表示し、email inputは出さない' do
      user = create(:user, email: 'contact-user@example.com', name: '登録 花子')
      sign_in user

      get contact_path

      document = Nokogiri::HTML(response.body)
      sender_name_input = document.at_css('input[name="contact_request[sender_name]"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('contact-user@example.com')
        expect(document.at_css('input[name="contact_request[email]"]')).to be_nil
        expect(sender_name_input['value']).to eq('登録 花子')
        expect(sender_name_input['required']).to be_nil
      end
    end
  end

  describe 'POST /contact' do
    it 'logged-in userの問い合わせを作成し、user.emailを使う' do
      user = create(:user, email: 'registered@example.com')
      sign_in user

      expect {
        post_contact(params: valid_contact_params(email: 'other@example.com'))
      }.to change(ContactRequest, :count).by(1)

      contact_request = ContactRequest.last

      aggregate_failures do
        expect(response).to redirect_to(contact_path)
        expect(flash[:notice]).to eq(I18n.t('contact_requests.messages.created'))
        expect(contact_request.user).to eq(user)
        expect(contact_request.email).to eq('registered@example.com')
        expect(contact_request.sender_name).to eq('送信 太郎')
        expect(contact_request.source).to eq('authenticated')
      end
    end

    it 'guest userの問い合わせを作成する' do
      guest = create(:user, guest: true)
      sign_in guest

      expect {
        post_contact(params: valid_contact_params(email: 'guest-reply@example.com'))
      }.to change(ContactRequest, :count).by(1)

      contact_request = ContactRequest.last

      aggregate_failures do
        expect(contact_request.user).to eq(guest)
        expect(contact_request.email).to eq('guest-reply@example.com')
        expect(contact_request.sender_name).to eq('送信 太郎')
        expect(contact_request.source).to eq('guest')
      end
    end

    it '未ログインの問い合わせを作成する' do
      expect {
        post_contact(params: valid_contact_params(email: 'public-reply@example.com'))
      }.to change(ContactRequest, :count).by(1)

      contact_request = ContactRequest.last

      aggregate_failures do
        expect(contact_request.user).to be_nil
        expect(contact_request.email).to eq('public-reply@example.com')
        expect(contact_request.sender_name).to eq('送信 太郎')
        expect(contact_request.source).to eq('public')
      end
    end

    it 'sender_nameがblankならnilで保存する' do
      expect {
        post_contact(params: valid_contact_params(email: 'blank-name@example.com', sender_name: '   '))
      }.to change(ContactRequest, :count).by(1)

      expect(ContactRequest.last.sender_name).to be_nil
    end

    it 'login_restricted中はTurnstile検証前に拒否し、問い合わせと通知メールを作成しない' do
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))
      ActionMailer::Base.deliveries.clear
      expect(BotProtection).not_to receive(:verify_turnstile)

      expect {
        post_contact(params: valid_contact_params(email: 'maintenance-contact@example.com'))
      }.not_to change(ContactRequest, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('shared.maintenance_mode.body'))
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'Turnstile有効時にtokenなしなら問い合わせを作成せず通知メールも送らない' do
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.failure_result("turnstile_token_missing"))
      expect(ContactRequestMailer).not_to receive(:admin_notification)
      expect(ContactRequestMailer).not_to receive(:auto_reply)

      expect {
        post_contact(params: valid_contact_params(email: 'turnstile-missing@example.com'))
      }.not_to change(ContactRequest, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.bot_protection.verification_failed'))
      end
    end

    it 'Turnstile検証失敗時は問い合わせを作成しない' do
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.failure_result("turnstile_verification_failed"))
      expect(ContactRequestMailer).not_to receive(:auto_reply)

      expect {
        post contact_path,
          params: {
            "cf-turnstile-response" => "invalid-token",
            contact_request: valid_contact_params(email: 'turnstile-failed@example.com')
          }
      }.not_to change(ContactRequest, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'Turnstile検証成功時は既存の問い合わせ作成flowを維持する' do
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.success_result)

      expect {
        post contact_path,
          params: {
            "cf-turnstile-response" => "valid-token",
            contact_request: valid_contact_params(email: 'turnstile-success@example.com')
          }
      }.to change(ContactRequest, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(contact_path)
        expect(flash[:notice]).to eq(I18n.t('contact_requests.messages.created'))
      end
    end

    it 'validation errorを表示する' do
      expect {
        post_contact(params: valid_contact_params(email: '', subject: '', body: ''))
      }.not_to change(ContactRequest, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('contact_requests.messages.create_failed'))
      end
    end

    it 'honeypot入力は保存せず成功扱いにする' do
      expect {
        post_contact(params: valid_contact_params(company_name: 'bot'))
      }.not_to change(ContactRequest, :count)

      aggregate_failures do
        expect(response).to redirect_to(contact_path)
        expect(flash[:notice]).to eq(I18n.t('contact_requests.messages.created'))
      end
    end

    it 'public IPを3件/日でrate limitする' do
      3.times do
        post_contact(params: valid_contact_params(email: 'limit-ip@example.com'), ip: '203.0.113.20')
        expect(response).to redirect_to(contact_path)
      end

      post_contact(params: valid_contact_params(email: 'limit-ip-2@example.com'), ip: '203.0.113.20')

      expect(response).to have_http_status(:too_many_requests)
    end

    it '同じemail digestを3件/日でrate limitし、cache keyに平文emailを含めない' do
      3.times do |index|
        post_contact(
          params: valid_contact_params(email: 'Same.Address@Example.com', subject: "問い合わせ#{index}"),
          ip: "203.0.113.#{30 + index}"
        )
      end

      post_contact(params: valid_contact_params(email: 'same.address@example.com'), ip: '203.0.113.40')

      keys = rate_limit_store.instance_variable_get(:@data).keys.join(' ')

      aggregate_failures do
        expect(response).to have_http_status(:too_many_requests)
        expect(keys).not_to include('Same.Address@Example.com')
        expect(keys).not_to include('same.address@example.com')
        expect(keys).to match(/[a-f0-9]{64}/)
      end
    end

    it 'logged-in userを5件/日でrate limitする' do
      user = create(:user)
      sign_in user

      5.times do |index|
        post_contact(params: valid_contact_params(subject: "問い合わせ#{index}"))
        expect(response).to redirect_to(contact_path)
      end

      post_contact(params: valid_contact_params(subject: '問い合わせ6'))

      expect(response).to have_http_status(:too_many_requests)
    end

    it '問い合わせ本文はAuditLogに保存しない' do
      sensitive_body = '問い合わせ本文に詳細を書きます。'

      expect {
        post_contact(params: valid_contact_params(body: sensitive_body))
      }.not_to change(AuditLog, :count)
    end
  end
end
