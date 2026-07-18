require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "アカウントとsecurityの実Chrome回帰", type: :system do
  include ActiveSupport::Testing::TimeHelpers

  before do
    ActionMailer::Base.deliveries.clear
    LegalDocuments::Sync.call
  end

  after do
    travel_back
    ActionMailer::Base.deliveries.clear
  end

  def submit_password_login(email:, password: "password")
    visit new_user_session_path
    fill_in "user_email", with: email
    fill_in "user_password", with: password
    click_button I18n.t("auth.sessions.submit")
  end

  def sign_in_through_browser(user)
    submit_password_login(email: user.email)
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  def open_logout_confirmation
    click_button I18n.t("common.logout")
    find("dialog#confirm-dialog[open]")
  end

  def sign_out_through_browser(verify_cancel: false)
    original_path = page.current_path

    if verify_cancel
      within(open_logout_confirmation) do
        click_button I18n.t("shared.confirm_dialog.cancel")
      end
      expect(page).to have_no_css("dialog#confirm-dialog[open]")
      expect(page).to have_current_path(original_path, ignore_query: true)
      expect(page).to have_button(I18n.t("common.logout"))
    end

    dialog = open_logout_confirmation
    expect(page).to have_current_path(original_path, ignore_query: true)
    within(dialog) do
      click_button I18n.t("common.logout")
    end
    expect(page).to have_current_path(root_path, ignore_query: true)
  end

  def confirmation_token_from(message)
    body = message.html_part&.body&.decoded || message.body.decoded
    CGI.unescapeHTML(body.match(/confirmation_token=([^"'&\s]+)/)[1])
  end

  def totp_code(secret)
    ROTP::TOTP.new(secret, issuer: "Recify").now
  end

  it "signupで法務同意を記録し、confirmation後にsettings更新とlogoutができる" do
    email = "chrome-signup@example.com"

    visit new_user_registration_path
    wait_for_stimulus_controller("legal-dialog")
    within("section[aria-label='#{I18n.t("auth.registrations.new.terms.aria_label")}']") do
      click_link I18n.t("auth.registrations.new.terms.terms")
    end
    expect(page).to have_css("dialog#registration-terms-dialog[open]")
    within("dialog#registration-terms-dialog") do
      click_button I18n.t("legal.dialog.close")
    end
    expect(page).to have_no_css("dialog#registration-terms-dialog[open]")

    fill_in "user_email", with: email
    fill_in "user_password", with: "password"
    fill_in "user_password_confirmation", with: "password"
    check "registration_legal_agreement"
    click_button I18n.t("auth.registrations.new.submit")

    expect(page).to have_current_path(new_user_session_path, ignore_query: true)
    user = User.find_by!(email:)
    aggregate_failures do
      expect(user).not_to be_confirmed
      expect(user.legal_acceptances.pluck(:document_type)).to contain_exactly("terms", "privacy")
      expect(user.legal_acceptances).to all(have_attributes(acceptance_context: "signup"))
      expect(ActionMailer::Base.deliveries.size).to eq(1)
    end

    visit user_confirmation_path(
      confirmation_token: confirmation_token_from(ActionMailer::Base.deliveries.last)
    )
    expect(page).to have_current_path(new_user_session_path, ignore_query: true)
    expect(user.reload).to be_confirmed

    sign_in_through_browser(user)
    visit settings_account_path
    wait_for_stimulus_controller("avatar-preview")
    fill_in "user_name", with: "Chrome確認ユーザー"
    click_button I18n.t("settings.account.buttons.save")

    expect(page).to have_current_path(settings_path, ignore_query: true)
    expect(page).to have_link(
      I18n.t("settings.index.user.edit_profile"),
      href: settings_account_path
    )
    expect(user.reload.name).to eq("Chrome確認ユーザー")
    sign_out_through_browser(verify_cancel: true)
    expect_browser_console_clean
  end

  it "guest loginではguest境界を維持して本登録導線を表示する" do
    visit new_user_session_path
    click_button I18n.t("auth.sessions.guest.button")

    expect(page).to have_current_path(receipts_path, ignore_query: true)
    guest = User.order(:id).last
    expect(guest).to be_guest

    visit settings_security_path
    expect(page).to have_css("#guest-registration")
    expect(page).to have_content(I18n.t("settings.security.guest_registration.title"))
    sign_out_through_browser
    expect_browser_console_clean
  end

  it "TOTPを設定し、TOTPとrecovery codeの両方でstep-upできる" do
    user = create_system_test_user
    sign_in_through_browser(user)

    visit new_settings_security_totp_path
    wait_for_stimulus_controller("clipboard")
    secret = find("#totp-secret").value
    fill_in "code", with: totp_code(secret)
    click_button I18n.t("settings.security.auth.two_factor.setup.submit")

    expect(page).to have_content(I18n.t("settings.security.auth.recovery_codes.title"))
    recovery_codes = all("[data-clipboard-target='source'] code").map { |node| node.text.strip }
    credential = user.reload.totp_credential
    aggregate_failures do
      expect(credential).to be_confirmed
      expect(credential.totp_secret).to eq(secret)
      expect(recovery_codes.size).to eq(10)
      expect(user.recovery_codes.count).to eq(10)
    end

    click_link I18n.t("settings.security.auth.recovery_codes.done")
    expect(page).to have_current_path(settings_security_path, ignore_query: true)
    sign_out_through_browser

    travel 31.seconds
    submit_password_login(email: user.email)
    expect(page).to have_current_path(users_two_factor_totp_path, ignore_query: true)
    fill_in "code", with: totp_code(secret)
    click_button I18n.t("auth.two_factor.totp.button")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
    expect(UserSession.order(:id).last.sign_in_method).to eq("password_totp_step_up")
    sign_out_through_browser

    submit_password_login(email: user.email)
    expect(page).to have_current_path(users_two_factor_totp_path, ignore_query: true)
    click_link I18n.t("auth.two_factor.links.recovery_code")
    expect(page).to have_current_path(users_two_factor_recovery_code_path, ignore_query: true)
    fill_in "code", with: recovery_codes.first
    click_button I18n.t("auth.two_factor.recovery_code.button")

    expect(page).to have_current_path(receipts_path, ignore_query: true)
    used_code = user.recovery_codes.find_by!(
      code_digest: TwoFactor.recovery_code_digest(recovery_codes.first)
    )
    aggregate_failures do
      expect(used_code.used_at).to be_present
      expect(UserSession.order(:id).last.sign_in_method).to eq("password_recovery_code_step_up")
    end
    expect_browser_console_clean
  end
end
