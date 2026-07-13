require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "通知サーフェスの実Chrome回帰", type: :system do
  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  it "390pxでcontainerごとに最新5件を残しTurbo cache前に全件削除する", :mobile do
    user = create_system_test_user(theme_preference: "dark")
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true
    )
    sign_in_through_browser(user)

    page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[arguments.length - 1]
      const stream = document.getElementById('toast-stream')
      stream.dataset.noticeSurfaceContainer = 'true'
      stream.dataset.noticeSurfaceMaxVisible = '5'

      const secondary = document.createElement('div')
      secondary.id = 'secondary-toast-container'
      secondary.dataset.noticeSurfaceContainer = 'true'
      secondary.dataset.noticeSurfaceMaxVisible = '3'
      document.body.appendChild(secondary)

      const appendNotice = (container, id, message) => {
        const notice = document.createElement('div')
        notice.id = id
        notice.textContent = message
        notice.dataset.controller = 'notice-surface'
        notice.dataset.noticeSurfaceAnimationValue = 'slide_right'
        notice.dataset.noticeSurfaceAutoDismissValue = 'false'
        notice.dataset.noticeSurfaceRemoveBeforeCacheValue = 'true'
        container.appendChild(notice)
      }

      appendNotice(secondary, 'secondary-toast', 'secondary')
      ;(async () => {
        for (let index = 1; index <= 6; index += 1) {
          appendNotice(stream, `dynamic-toast-${index}`, `toast-${index}`)
          await new Promise((resolve) => window.setTimeout(resolve, 25))
        }
        done(true)
      })()
    JAVASCRIPT

    expect(page).to have_css("#toast-stream > [data-controller~='notice-surface']", count: 5)
    expect(page).not_to have_css("#dynamic-toast-1")
    expect(page).to have_css("#dynamic-toast-6")
    expect(page).to have_css("#secondary-toast")

    visible_ids = page.evaluate_script(<<~JAVASCRIPT)
      Array.from(document.querySelectorAll('#toast-stream > [data-controller~="notice-surface"]')).map((element) => element.id)
    JAVASCRIPT

    aggregate_failures do
      expect(visible_ids).to eq((2..6).map { |index| "dynamic-toast-#{index}" })
      expect(page.evaluate_script("window.innerWidth")).to eq(390)
      expect(page.evaluate_script("document.documentElement.scrollWidth")).to eq(390)
      expect(page.evaluate_script("document.documentElement.dataset.theme")).to eq("dark")
    end

    page.execute_script("document.dispatchEvent(new Event('turbo:before-cache'))")

    expect(page).to have_no_css("[data-controller~='notice-surface']")
    expect_browser_console_clean
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
