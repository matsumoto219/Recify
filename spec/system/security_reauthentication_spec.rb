require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "セキュリティ設定の本人確認", type: :system do
  include ActiveSupport::Testing::TimeHelpers

  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  def with_mobile_viewport
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true
    )
    yield
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  def expect_only_expected_browser_failures(*patterns)
    severe_entries = page.driver.browser.logs.get(:browser).select do |entry|
      entry.level == "SEVERE" && !blocked_external_font_entry?(entry)
    end
    expected_entries, unexpected_entries = severe_entries.partition do |entry|
      patterns.any? { |pattern| entry.message.match?(pattern) }
    end

    aggregate_failures do
      expect(expected_entries.size).to be >= patterns.size
      expect(unexpected_entries).to be_empty
    end
  end

  it "期限切れ時のpasskey preloadでは遷移せず、登録操作後だけ本人確認して元へ戻る", :mobile do
    with_mobile_viewport do
      user = create_system_test_user
      sign_in_through_browser(user)

      travel 6.minutes do
        visit settings_security_path(anchor: "passkeys")
        wait_for_stimulus_controller("passkey")
        expect(page).to have_current_path(settings_security_path, ignore_query: true)
        expect(page.evaluate_script("window.location.hash")).to eq("#passkeys")

        click_button I18n.t("settings.security.auth.passkey.action")

        expect(page).to have_current_path(new_settings_security_reauthentication_path, ignore_query: true)
        expect(page).to have_content(I18n.t("settings.security.reauthentication.messages.expired"))
        expect(page).to have_css("#flash [role='status'].notice-surface-warning")
        fill_in "password", with: "wrong-local-secret"
        click_button I18n.t("settings.security.reauthentication.submit")

        expect(page).to have_content(I18n.t("settings.security.reauthentication.messages.failed"))
        expect(page).to have_css("#flash [role='alert'][aria-live='assertive'].notice-surface-error")
        expect(find("input[name='password']").value).to eq("")

        fill_in "password", with: "password"
        click_button I18n.t("settings.security.reauthentication.submit")

        expect(page).to have_current_path(settings_security_path, ignore_query: true)
        expect(page.evaluate_script("window.location.hash")).to eq("#passkeys")
        expect(page).to have_content(I18n.t("settings.security.reauthentication.messages.succeeded"))
        expect(page.evaluate_script("window.innerWidth")).to eq(390)
        expect(page.evaluate_script("document.documentElement.scrollWidth")).to eq(390)
        expect_only_expected_browser_failures(
          %r{/settings/passkeys/options.+428},
          %r{/settings/security/reauthentication.+422}
        )
      end
    end
  end
end
