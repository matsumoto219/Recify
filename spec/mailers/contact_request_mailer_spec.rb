require 'rails_helper'

RSpec.describe ContactRequestMailer, type: :mailer do
  around do |example|
    original_support_email = ENV["SUPPORT_NOTIFICATION_EMAIL"]
    ENV["SUPPORT_NOTIFICATION_EMAIL"] = "support@example.com"

    example.run
  ensure
    ENV["SUPPORT_NOTIFICATION_EMAIL"] = original_support_email if original_support_email
    ENV.delete("SUPPORT_NOTIFICATION_EMAIL") unless original_support_email
  end

  describe '.admin_notification_enabled?' do
    it 'SUPPORT_NOTIFICATION_EMAILがあればtrue' do
      expect(described_class.admin_notification_enabled?).to be(true)
    end
  end

  describe '#admin_notification' do
    def decoded_mail_body(mail)
      [ mail.text_part&.body&.decoded, mail.html_part&.body&.decoded, mail.body.decoded ].compact.join("\n")
    end

    it 'admin宛に問い合わせ通知を送る' do
      contact_request = create(:contact_request, category: 'security', subject: '安全性の相談')

      mail = described_class.admin_notification(contact_request)
      body = decoded_mail_body(mail)

      aggregate_failures do
        expect(mail.to).to eq([ 'support@example.com' ])
        expect(mail.subject).to include(contact_request.request_uid, I18n.t('contact_requests.categories.security'))
        expect(body).to include(contact_request.request_uid)
        expect(body).to include(I18n.l(contact_request.created_at, format: :long))
        expect(body).to include(I18n.t("contact_requests.sources.#{contact_request.source}"))
        expect(body).to include(contact_request.request_id)
        expect(body).to include("http://example.com/admin/contact_requests/#{contact_request.id}")
      end
    end

    it '本文全文や秘密情報をメール本文に載せない' do
      body = 'password recovery code TOTP secret cookie session を含む長い問い合わせ本文'
      contact_request = create(:contact_request, email: 'sender@example.com', body: body)

      mail_body = decoded_mail_body(described_class.admin_notification(contact_request))

      aggregate_failures do
        expect(mail_body).not_to include(body)
        expect(mail_body).not_to include('password recovery code TOTP secret cookie session')
        expect(mail_body).not_to include('sender@example.com')
        expect(mail_body).to include(contact_request.email_digest.first(12))
      end
    end
  end
end
