require 'rails_helper'

RSpec.describe ContactRequests do
  include ActiveJob::TestHelper

  let(:request) do
    instance_double(
      ActionDispatch::Request,
      remote_ip: '203.0.113.44',
      user_agent: 'RSpec browser',
      request_id: 'request-id-1'
    )
  end

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    original_support_email = ENV["SUPPORT_NOTIFICATION_EMAIL"]
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
    ENV.delete("SUPPORT_NOTIFICATION_EMAIL")

    example.run
  ensure
    ENV["SUPPORT_NOTIFICATION_EMAIL"] = original_support_email if original_support_email
    ENV.delete("SUPPORT_NOTIFICATION_EMAIL") unless original_support_email
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = original_adapter
  end

  def valid_params(overrides = {})
    {
      email: ' Sender@Example.com ',
      category: 'account',
      subject: 'ログインについて',
      body: 'ログインについて相談したいです。',
      company_name: ''
    }.merge(overrides)
  end

  describe '.create' do
    it 'logged-in userはauthenticated sourceになりuser.emailを使う' do
      user = create(:user, email: 'user@example.com')

      result = described_class.create(
        user: user,
        params: valid_params(email: 'other@example.com', sender_name: '  登録 太郎  '),
        request: request
      )

      aggregate_failures do
        expect(result).to be_success
        expect(result.contact_request).to be_persisted
        expect(result.contact_request.source).to eq('authenticated')
        expect(result.contact_request.email).to eq('user@example.com')
        expect(result.contact_request.sender_name).to eq('登録 太郎')
        expect(result.contact_request.user).to eq(user)
      end
    end

    it 'guest userはguest sourceになり入力emailを使う' do
      guest = create(:user, guest: true)

      result = described_class.create(user: guest, params: valid_params(email: 'guest-contact@example.com'), request: request)

      aggregate_failures do
        expect(result).to be_success
        expect(result.contact_request.source).to eq('guest')
        expect(result.contact_request.email).to eq('guest-contact@example.com')
      end
    end

    it 'sender_nameがblankならnilに正規化する' do
      result = described_class.create(user: nil, params: valid_params(sender_name: '   '), request: request)

      aggregate_failures do
        expect(result).to be_success
        expect(result.contact_request.sender_name).to be_nil
      end
    end

    it 'unauthenticated userはpublic sourceになる' do
      result = described_class.create(user: nil, params: valid_params(email: 'public@example.com'), request: request)

      aggregate_failures do
        expect(result).to be_success
        expect(result.contact_request.source).to eq('public')
        expect(result.contact_request.user).to be_nil
      end
    end

    it 'email_digestに平文emailを含めない' do
      result = described_class.create(user: nil, params: valid_params(email: 'Secret.Person@Example.com'), request: request)

      aggregate_failures do
        expect(result.contact_request.email_digest).to match(/\A[a-f0-9]{64}\z/)
        expect(result.contact_request.email_digest).not_to include('Secret.Person')
        expect(result.contact_request.email_digest).not_to include('secret.person@example.com')
      end
    end

    it 'honeypot入力は保存せず成功扱いにする' do
      result = nil

      expect {
        result = described_class.create(user: nil, params: valid_params(company_name: 'bot company'), request: request)
      }.not_to change(ContactRequest, :count)

      aggregate_failures do
        expect(result).to be_success
        expect(result).to be_spam
        expect(result.contact_request).not_to be_persisted
        expect(enqueued_jobs).to be_empty
      end
    end

    it 'URL大量投稿を拒否する' do
      body = 6.times.map { |index| "https://example.com/#{index}" }.join("\n")

      result = described_class.create(user: nil, params: valid_params(body: body), request: request)

      aggregate_failures do
        expect(result).not_to be_success
        expect(result.contact_request).not_to be_persisted
        expect(result.contact_request.errors[:body]).to be_present
      end
    end

    it '設定されたURL上限で問い合わせ本文を検証する' do
      create(:system_setting, key: 'limits.contact_request_url_count', value: SystemSettings.stored_value(2))
      allowed_body = 2.times.map { |index| "https://example.com/allowed-#{index}" }.join("\n")
      rejected_body = 3.times.map { |index| "https://example.com/rejected-#{index}" }.join("\n")

      allowed_result = described_class.create(user: nil, params: valid_params(body: allowed_body), request: request)
      rejected_result = described_class.create(user: nil, params: valid_params(body: rejected_body), request: request)

      aggregate_failures do
        expect(described_class.max_url_count).to eq(2)
        expect(allowed_result).to be_success
        expect(allowed_result.contact_request).to be_persisted
        expect(rejected_result).not_to be_success
        expect(rejected_result.contact_request).not_to be_persisted
        expect(rejected_result.contact_request.errors[:body]).to be_present
      end
    end

    it 'body/subject length validationを返す' do
      result = described_class.create(
        user: nil,
        params: valid_params(subject: 'a' * 161, body: 'b' * 5001),
        request: request
      )

      aggregate_failures do
        expect(result).not_to be_success
        expect(result.contact_request.errors[:subject]).to be_present
        expect(result.contact_request.errors[:body]).to be_present
      end
    end

    it '作成時にadmin通知メールをenqueueする' do
      ENV["SUPPORT_NOTIFICATION_EMAIL"] = "support@example.com"

      expect {
        described_class.create(user: nil, params: valid_params(email: 'mail@example.com'), request: request)
      }.to have_enqueued_mail(ContactRequestMailer, :admin_notification)
    end

    it '作成時に問い合わせ受付メールをenqueueする' do
      expect {
        described_class.create(user: nil, params: valid_params(email: 'auto-reply@example.com'), request: request)
      }.to have_enqueued_mail(ContactRequestMailer, :auto_reply)
    end

    it 'SUPPORT_NOTIFICATION_EMAIL未設定でも問い合わせ保存と自動返信enqueueは成功する' do
      result = nil
      expect(Rails.logger).to receive(:warn).with(/\[ContactRequest\] support_notification_email_missing request_uid=/)

      expect {
        result = described_class.create(user: nil, params: valid_params(email: 'no-mail@example.com'), request: request)
      }.not_to have_enqueued_mail(ContactRequestMailer, :admin_notification)

      aggregate_failures do
        expect(result).to be_success
        expect(result.contact_request).to be_persisted
        expect(enqueued_jobs).to include(
          hash_including(args: include("ContactRequestMailer", "auto_reply"))
        )
      end
    end
  end

  describe '.category_options' do
    it 'returns category values through the public entrypoint' do
      expect(described_class.category_options).to eq(ContactRequest::CATEGORIES)
    end
  end
end
