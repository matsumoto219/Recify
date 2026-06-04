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
      expect(html).to include('@media screen and (max-width: 600px)')
      expect(html).to include('class="mailer-shell"')
      expect(html).to include('class="mailer-brand"')
      expect(html).to include('class="mailer-panel"')
      expect(html).to include('class="mailer-panel-content"')
      expect(html).to include('bgcolor="#f5f7fb"')
      expect(html).to include('background-color: #f5f7fb; color: #4d4b5f')
      expect(html).to include('bgcolor="#ffffff"')
      expect(html).to include('background-color: #ffffff; color: #4d4b5f; color-scheme: light; border: 1px solid #f0f0f0; border-radius: 12px; border-collapse: separate; border-spacing: 0')
      expect(html).to include('class="mailer-panel-content" style="padding: 44px 40px;"')
      expect(html).to include('border: 1px solid #f0f0f0')
      expect(html).to include('color: #4b4dd8')
      expect(html).to include('border-radius: 12px')
      expect(html).to include('border-collapse: separate')
      expect(html).to include('border-spacing: 0')
      expect(html).to include('box-shadow: 0 1px 4px rgba(0, 0, 0, 0.05)')
      expect(html).not_to include('class="mailer-panel" bgcolor="#ffffff" style="background-color: #ffffff; color: #4d4b5f; color-scheme: light; padding: 44px 40px; border:')
      expect(html).to include('color-scheme: light')
      expect(html).to include('color: #1c1b1b')
      expect(html).to include(I18n.t('auth.mailer.layout.app_name'))
      expect(html).to include(I18n.t('auth.mailer.layout.tagline'))
      expect(html).to include(I18n.t('auth.mailer.layout.footer_notice'))
      expect(html).to include(I18n.t('auth.mailer.layout.copyright', year: Time.current.year))
      expect(html).not_to include('InfinityFree')
      expect(html).not_to include('data:image')
      expect(html).not_to include('@import')
      expect(html).not_to include('Open Sans')
      expect(html).not_to include('background-color: #353534')
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

  def mailer_duration_text(duration)
    seconds = duration.to_i
    unit, divisor = {
      days: 1.day.to_i,
      hours: 1.hour.to_i,
      minutes: 1.minute.to_i
    }.find { |_key, value| seconds >= value && (seconds % value).zero? } || [ :seconds, 1 ]

    I18n.t("auth.mailer.common.duration.#{unit}", count: seconds / divisor)
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
      expect(text_body(mail)).to include(
        I18n.t('auth.mailer.confirmation_instructions.expires_in', duration: mailer_duration_text(user.class.confirm_within))
      )
      expect(html_body(mail)).to include(I18n.t('auth.mailer.confirmation_instructions.action'))
      expect(html_body(mail)).to include(
        I18n.t('auth.mailer.confirmation_instructions.expires_in', duration: mailer_duration_text(user.class.confirm_within))
      )
    end
  end

  it 'reset password instructionsはtext/plainとtext/htmlのmultipartで送る' do
    user = create(:user, email: 'reset-multipart@example.com')
    mail = Devise::Mailer.reset_password_instructions(user, 'reset-token')

    aggregate_failures do
      expect_devise_multipart(mail)
      expect(text_body(mail)).to include('reset-multipart@example.com')
      expect(text_body(mail)).to include('reset_password_token=reset-token')
      expect(text_body(mail)).to include(
        I18n.t('auth.mailer.reset_password_instructions.expires_in', duration: mailer_duration_text(user.class.reset_password_within))
      )
      expect(text_body(mail)).to include(I18n.t('auth.mailer.reset_password_instructions.single_use'))
      expect(text_body(mail)).to include(I18n.t('auth.mailer.reset_password_instructions.protect_account'))
      expect(html_body(mail)).to include(I18n.t('auth.mailer.reset_password_instructions.action'))
      expect(html_body(mail)).to include(
        I18n.t('auth.mailer.reset_password_instructions.expires_in', duration: mailer_duration_text(user.class.reset_password_within))
      )
      expect(html_body(mail)).to include(I18n.t('auth.mailer.reset_password_instructions.single_use'))
      expect(html_body(mail)).to include(I18n.t('auth.mailer.reset_password_instructions.protect_account'))
    end
  end

  it 'unlock instructionsはtext/plainとtext/htmlのmultipartで送る' do
    user = create(:user, email: 'unlock-multipart@example.com')
    mail = Devise::Mailer.unlock_instructions(user, 'unlock-token')

    aggregate_failures do
      expect_devise_multipart(mail)
      expect(text_body(mail)).to include('unlock-multipart@example.com')
      expect(text_body(mail)).to include('unlock_token=unlock-token')
      expect(text_body(mail)).to include(
        I18n.t('auth.mailer.unlock_instructions.auto_unlock', duration: mailer_duration_text(user.class.unlock_in))
      )
      expect(text_body(mail)).to include(I18n.t('auth.mailer.unlock_instructions.ignore'))
      expect(html_body(mail)).to include(I18n.t('auth.mailer.unlock_instructions.action'))
      expect(html_body(mail)).to include(
        I18n.t('auth.mailer.unlock_instructions.auto_unlock', duration: mailer_duration_text(user.class.unlock_in))
      )
      expect(html_body(mail)).to include(I18n.t('auth.mailer.unlock_instructions.ignore'))
    end
  end

  it 'email changedはtext/plainとtext/htmlのmultipartで送る' do
    user = create(:user, email: 'old-email-multipart@example.com')
    user.unconfirmed_email = 'new-email-multipart@example.com'
    mail = Devise::Mailer.email_changed(user)

    aggregate_failures do
      expect_devise_multipart(mail)
      expect(mail.subject).to eq(I18n.t('devise.mailer.email_changed.subject'))
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
      expect(text_body(mail)).to include(I18n.t('auth.mailer.password_change.ignore'))
      expect(text_body(mail)).not_to include(I18n.t('auth.mailer.common.fallback_url'))
      expect(html_body(mail)).to include(I18n.t('auth.mailer.password_change.title'))
      expect(html_body(mail)).to include(I18n.t('auth.mailer.password_change.ignore'))
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
