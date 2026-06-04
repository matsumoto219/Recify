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
      category: 'account',
      subject: '問い合わせ件名',
      body: '問い合わせ本文です。',
      company_name: ''
    }.merge(overrides)
  end

  def post_contact(params: valid_contact_params, ip: '203.0.113.10')
    post contact_path, params: { contact_request: params }, headers: { 'REMOTE_ADDR' => ip }
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
      category_select = document.at_css("select[name='contact_request[category]']")
      category_first_option = category_select.at_css('option:first-child')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('contact_requests.new.title'))
        expect(category_first_option['value']).to eq('')
        expect(category_first_option.text).to eq(I18n.t('contact_requests.placeholders.category'))
        expect(category_select.at_css("option[value='other'][selected]")).to be_nil
        expect(safety_text).to include('安全のため、必要な範囲の情報のみ入力してください。')
        expect(safety_text).to include('個人情報')
        expect(safety_text).to include('パスワード')
        expect(safety_text).to include('認証コード')
        expect(safety_text).to include('復旧用コード')
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

      aggregate_failures do
        expect(document.at_css('.cf-turnstile')['data-sitekey']).to eq('test_site_key')
        expect(document.at_css("script[src='https://challenges.cloudflare.com/turnstile/v0/api.js']")).to be_present
        expect(response.body).not_to include('test_secret_key')
      end
    end

    it 'Turnstile無効時はwidgetを表示しない' do
      with_turnstile_env(enabled: false, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        get contact_path
      end

      expect(response.body).not_to include('cf-turnstile')
    end

    it 'logged-in userには返信先emailを表示し、email inputは出さない' do
      user = create(:user, email: 'contact-user@example.com')
      sign_in user

      get contact_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('contact-user@example.com')
        expect(document.at_css('input[name="contact_request[email]"]')).to be_nil
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
        expect(contact_request.source).to eq('public')
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
