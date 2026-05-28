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

  def text_body(mail)
    mail.text_part&.body&.decoded || mail.body.decoded
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

  def expect_devise_multipart(mail)
    aggregate_failures do
      expect(mail).to be_multipart
      expect(mail.parts.map(&:mime_type)).to eq([ "text/plain", "text/html" ])
      expect(mail.text_part).to be_present
      expect(mail.html_part).to be_present
      expect(text_body(mail)).not_to match(/<\/?[a-z][^>]*>/i)
      expect(html_body(mail)).to include("<!DOCTYPE html>")
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

  it 'confirmation instructionsはtext/plainとtext/htmlのmultipartで送る' do
    user = create(:user, email: 'confirm-multipart@example.com')
    mail = Devise::Mailer.confirmation_instructions(user, 'confirmation-token')

    aggregate_failures do
      expect_devise_multipart(mail)
      expect(text_body(mail)).to include('confirm-multipart@example.com')
      expect(text_body(mail)).to include('confirmation_token=confirmation-token')
      expect(html_body(mail)).to include(I18n.t('auth.mailer.confirmation_instructions.action'))
    end
  end

  it 'reset password instructionsはtext/plainとtext/htmlのmultipartで送る' do
    user = create(:user, email: 'reset-multipart@example.com')
    mail = Devise::Mailer.reset_password_instructions(user, 'reset-token')

    aggregate_failures do
      expect_devise_multipart(mail)
      expect(text_body(mail)).to include('reset-multipart@example.com')
      expect(text_body(mail)).to include('reset_password_token=reset-token')
      expect(html_body(mail)).to include(I18n.t('auth.mailer.reset_password_instructions.action'))
    end
  end

  it 'unlock instructionsはtext/plainとtext/htmlのmultipartで送る' do
    user = create(:user, email: 'unlock-multipart@example.com')
    mail = Devise::Mailer.unlock_instructions(user, 'unlock-token')

    aggregate_failures do
      expect_devise_multipart(mail)
      expect(text_body(mail)).to include('unlock-multipart@example.com')
      expect(text_body(mail)).to include('unlock_token=unlock-token')
      expect(html_body(mail)).to include(I18n.t('auth.mailer.unlock_instructions.action'))
    end
  end

  it 'email changedはtext/plainとtext/htmlのmultipartで送る' do
    user = create(:user, email: 'old-email-multipart@example.com')
    user.unconfirmed_email = 'new-email-multipart@example.com'
    mail = Devise::Mailer.email_changed(user)

    aggregate_failures do
      expect_devise_multipart(mail)
      expect(text_body(mail)).to include('old-email-multipart@example.com')
      expect(text_body(mail)).to include('new-email-multipart@example.com')
      expect(text_body(mail)).not_to include(I18n.t('auth.mailer.common.fallback_url'))
      expect(html_body(mail)).to include(I18n.t('auth.mailer.email_changed.title'))
    end
  end

  it 'password changeはtext/plainとtext/htmlのmultipartで送る' do
    user = create(:user, email: 'password-change-multipart@example.com')
    mail = Devise::Mailer.password_change(user)

    aggregate_failures do
      expect_devise_multipart(mail)
      expect(text_body(mail)).to include('password-change-multipart@example.com')
      expect(text_body(mail)).to include(I18n.t('auth.mailer.password_change.body'))
      expect(text_body(mail)).not_to include(I18n.t('auth.mailer.common.fallback_url'))
      expect(html_body(mail)).to include(I18n.t('auth.mailer.password_change.title'))
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
