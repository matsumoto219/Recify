require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "メールアドレス選択コピーの実Chrome回帰", type: :system, mobile: true do
  before do
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true
    )
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  def dispatch_copy_event(selector, segment: nil)
    page.evaluate_script(<<~JAVASCRIPT, selector, segment)
      (() => {
        const selector = arguments[0]
        const segment = arguments[1]
        const display = document.querySelector(selector)
        const selectedNode = segment === null ? display : display.querySelectorAll(':scope > span')[segment]
        const selection = window.getSelection()
        const range = document.createRange()
        range.selectNodeContents(selectedNode)
        selection.removeAllRanges()
        selection.addRange(range)

        const clipboardData = new DataTransfer()
        const event = new ClipboardEvent('copy', {
          bubbles: true,
          cancelable: true,
          clipboardData
        })
        const dispatched = display.dispatchEvent(event)

        return {
          copiedText: clipboardData.getData('text/plain'),
          defaultPrevented: !dispatched,
          innerText: display.innerText,
          textContent: display.textContent
        }
      })()
    JAVASCRIPT
  end

  it "settingsのfull selectionだけをcanonical値へ変換し、部分選択は上書きしない" do
    email = "mobile-selection-copy-long-local-part-version123456789@example-long-domain.test"
    user = create_system_test_user(email:)
    sign_in_through_browser(user)
    visit settings_path
    wait_for_stimulus_controller("email-address-copy")
    selector = "[data-email-address-display][data-email-address-value='#{email}']"

    full_result = dispatch_copy_event(selector)
    partial_result = dispatch_copy_event(selector, segment: 0)

    aggregate_failures do
      expect(page.evaluate_script("window.innerWidth")).to eq(390)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      expect(full_result).to include(
        "copiedText" => email,
        "defaultPrevented" => true,
        "textContent" => email
      )
      expect(full_result.fetch("innerText")).to include("\n")
      expect(partial_result).to include("copiedText" => "", "defaultPrevented" => false)
    end
    expect_browser_console_clean
  end

  it "admin usersのone-line表示でもcanonical値をコピーする" do
    admin = create_system_test_user(admin: true)
    target_email = "admin-selection-copy-long-local-part-version123456789@example-long-domain.test"
    create(:user, email: target_email)
    sign_in_through_browser(admin)
    visit admin_users_path
    wait_for_stimulus_controller("email-address-copy")
    selector = "[data-email-address-display][data-email-address-value='#{target_email}']"

    result = dispatch_copy_event(selector)

    aggregate_failures do
      expect(page.evaluate_script("window.innerWidth")).to eq(390)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      expect(result).to include(
        "copiedText" => target_email,
        "defaultPrevented" => true,
        "textContent" => target_email
      )
    end
    expect_browser_console_clean
  end
end
