require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "設定保存の実Chrome回帰", type: :system do
  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  def attach_missing_avatar(user)
    blob = ActiveStorage::Blob.create!(
      key: SecureRandom.uuid,
      filename: "missing-avatar.jpg",
      content_type: "image/jpeg",
      metadata: {},
      service_name: ActiveStorage::Blob.service.name,
      byte_size: 1.kilobyte,
      checksum: SecureRandom.base64(16)
    )
    ActiveStorage::Attachment.create!(name: "avatar", record: user, blob: blob)
    user.reload
  end

  def expect_only_expected_browser_failures(*patterns)
    severe_entries = page.driver.browser.logs.get(:browser).select do |entry|
      entry.level == "SEVERE" && !blocked_external_font_entry?(entry)
    end
    expected_entries, unexpected_entries = severe_entries.partition do |entry|
      patterns.any? { |pattern| entry.message.match?(pattern) }
    end

    aggregate_failures do
      expect(expected_entries).not_to be_empty if patterns.any?
      expect(unexpected_entries).to be_empty
    end
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

  it "欠損した未変更avatarがあっても390pxでthemeを保存し再読み込み後も維持する", :mobile do
    with_mobile_viewport do
      user = create_system_test_user(theme_preference: "system")
      sign_in_through_browser(user)
      visit settings_path
      attach_missing_avatar(user)

      find("label[for='theme_preference_light']").click

      expect(page).to have_css("#theme_preference_light:checked", visible: :all)
      expect(page).to have_css("html[data-theme='light']")
      expect(page).to have_content(I18n.t("flash.settings.update_success"))
      expect(user.reload.theme_preference).to eq("light")
      expect(page.evaluate_script("window.innerWidth")).to eq(390)

      page.refresh

      expect(page).to have_css("#theme_preference_light:checked", visible: :all)
      expect(page).to have_css("html[data-theme='light']")
      expect(page.evaluate_script("document.documentElement.scrollWidth")).to eq(390)
      expect_only_expected_browser_failures(%r{/rails/active_storage/.+404})
    end
  end

  it "422ではradio・indicator・themeを保存済み値へ戻す" do
    user = create_system_test_user(theme_preference: "system")
    sign_in_through_browser(user)
    visit settings_path

    page.execute_script("document.getElementById('theme_preference_light').value = 'neon'")
    find("label[for='theme_preference_light']").click

    expect(page).to have_content(I18n.t("flash.settings.update_failure"))
    expect(page).to have_css("#theme_preference_system:checked", visible: :all)
    expect(page).to have_css("html[data-theme='system']")
    expect(
      page.evaluate_script(
        "document.getElementById('theme_preference_system').closest('fieldset').style.getPropertyValue('--segmented-active-index')"
      )
    ).to eq("0")
    expect(user.reload.theme_preference).to eq("system")
    expect_only_expected_browser_failures(%r{/settings.+422})
  end
end
