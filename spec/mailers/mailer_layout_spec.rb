require 'rails_helper'

RSpec.describe 'Mailer layout', type: :mailer do
  around do |example|
    original_support_email = ENV["SUPPORT_NOTIFICATION_EMAIL"]
    ENV["SUPPORT_NOTIFICATION_EMAIL"] = "support@example.com"

    example.run
  ensure
    ENV["SUPPORT_NOTIFICATION_EMAIL"] = original_support_email if original_support_email
    ENV.delete("SUPPORT_NOTIFICATION_EMAIL") unless original_support_email
  end

  def html_body(mail)
    mail.html_part&.body&.decoded || mail.body.decoded
  end

  def expect_soft_mailer_palette(html)
    aggregate_failures do
      expect(html).to include('<meta name="color-scheme" content="light">')
      expect(html).to include('<meta name="supported-color-schemes" content="light">')
      expect(html).to include(':root { color-scheme: light; supported-color-schemes: light; }')
      expect(html).to include('bgcolor="#ffffff"')
      expect(html).to include('background-color: #ffffff; color: #4d4b5f')
      expect(html).to include('bgcolor="#f7f7fb"')
      expect(html).to include('background-color: #f7f7fb; color: #4d4b5f')
      expect(html).to include('color-scheme: light')
      expect(html).to include('background-color: #353534')
      expect(html).to include('color: #1c1b1b')
      expect(html).not_to include('var(--')
      expect(html).not_to include('token-')
      expect(html).not_to include('#000000')
    end
  end

  it 'DeviseメールHTMLは柔らかい固定色とCTA背景色を明示する' do
    user = create(:user, email: 'mailer-layout@example.com')

    html = html_body(Devise::Mailer.confirmation_instructions(user, 'confirmation-token'))

    aggregate_failures do
      expect_soft_mailer_palette(html)
      expect(html).to include('bgcolor="#5a5cd6"')
      expect(html).to include('background-color: #5a5cd6')
      expect(html).to include('color: #f7f7fb !important')
      expect(html).to include('-webkit-text-fill-color: #f7f7fb')
      expect(html).to include('text-decoration: none')
    end
  end

  it '問い合わせ通知HTMLも同じメール用配色でレンダリングされる' do
    contact_request = create(:contact_request)

    html = html_body(ContactRequestMailer.admin_notification(contact_request))

    aggregate_failures do
      expect_soft_mailer_palette(html)
      expect(html).to include('background: #5a5cd6; background-color: #5a5cd6')
      expect(html).to include('color: #f7f7fb !important')
      expect(html).to include('-webkit-text-fill-color: #f7f7fb')
      expect(html).to include('text-decoration: none')
    end
  end
end
