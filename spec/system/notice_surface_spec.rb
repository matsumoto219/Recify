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

  def render_notice_surface(**locals)
    ApplicationController.render(
      partial: "shared/ui/feedback/notice_surface",
      locals: locals
    )
  end

  def append_notice(target:, **locals)
    surface = render_notice_surface(**locals)
    stream = <<~HTML
      <turbo-stream action="append" target="#{target}">
        <template>#{surface}</template>
      </turbo-stream>
    HTML

    turbo_ready = page.evaluate_async_script(<<~JAVASCRIPT, Capybara.default_max_wait_time * 1000)
      const timeoutMilliseconds = arguments[0]
      const done = arguments[arguments.length - 1]
      const deadline = window.performance.now() + timeoutMilliseconds

      const check = () => {
        if (typeof window.Turbo?.renderStreamMessage === 'function') {
          done(true)
          return
        }

        if (window.performance.now() >= deadline) {
          done(false)
          return
        }

        window.setTimeout(check, 25)
      }

      check()
    JAVASCRIPT
    expect(turbo_ready).to be(true), "Turbo stream renderer did not become available"

    page.execute_script("Turbo.renderStreamMessage(#{stream.to_json})")
    expect(page).to have_css("##{locals.fetch(:surface_id)}")
  end

  def surface_rect(selector)
    page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const rect = document.querySelector(#{selector.to_json}).getBoundingClientRect()
        return { top: rect.top, right: rect.right, bottom: rect.bottom, left: rect.left }
      })()
    JAVASCRIPT
  end

  def wait_for_surface_controller(selector, connected: true)
    result = page.evaluate_async_script(<<~JAVASCRIPT, selector, connected, Capybara.default_max_wait_time * 1000)
      const selector = arguments[0]
      const expectedConnected = arguments[1]
      const timeoutMilliseconds = arguments[2]
      const done = arguments[arguments.length - 1]
      const deadline = window.performance.now() + timeoutMilliseconds

      const check = () => {
        const element = document.querySelector(selector)
        const isConnected = (window.Stimulus?.controllers || []).some((controller) => controller.element === element)
        if (isConnected === expectedConnected) {
          done(true)
          return
        }

        if (window.performance.now() >= deadline) {
          done(false)
          return
        }

        window.setTimeout(check, 25)
      }

      check()
    JAVASCRIPT

    expect(result).to be(true)
  end

  it "flashと汎用toastを合計5件の共通stackへ古い順に表示する" do
    sign_in_through_browser(create_system_test_user)
    expect(page).to have_css("#flash [data-controller~='notice-surface']", count: 1)
    initial_flash_text = find("#flash [data-controller~='notice-surface']").text

    append_notice(
      target: "toast-stream",
      notice_type: :notice,
      message: "後から届いた通知B",
      dismissible: true,
      animated: true,
      animation_name: "slide_right",
      auto_dismiss: false,
      remove_before_cache: true,
      surface_id: "generic-toast-b",
      align: :center
    )
    append_notice(
      target: "toast-stream",
      notice_type: :notice,
      message: "さらに届いた通知C",
      dismissible: true,
      animated: true,
      animation_name: "slide_right",
      auto_dismiss: false,
      remove_before_cache: true,
      surface_id: "generic-toast-c",
      align: :center
    )

    flash_rect = surface_rect("#flash [data-controller~='notice-surface']")
    toast_b_rect = surface_rect("#generic-toast-b")
    toast_c_rect = surface_rect("#generic-toast-c")

    aggregate_failures do
      expect(toast_b_rect.fetch("top")).to be >= flash_rect.fetch("bottom")
      expect(toast_c_rect.fetch("top")).to be >= toast_b_rect.fetch("bottom")
      expect(page).to have_css("#flash[data-notice-surface-container][data-notice-surface-max-visible='5']")
      expect(page).to have_css("#flash [data-controller~='notice-surface']", count: 3)
      expect(page).to have_css("#flash > #toast-stream:not([data-notice-surface-container])")
      expect(page).to have_css("[data-notice-surface-container]", count: 1)
    end

    %w[d e f].each do |suffix|
      append_notice(
        target: "toast-stream",
        notice_type: :notice,
        message: "追加通知#{suffix.upcase}",
        auto_dismiss: false,
        remove_before_cache: true,
        surface_id: "generic-toast-#{suffix}"
      )
    end

    aggregate_failures do
      expect(page).to have_css("#flash [data-controller~='notice-surface']", count: 5)
      expect(page).to have_no_css("#flash [data-controller~='notice-surface']", text: initial_flash_text)
      expect(page).to have_css("#generic-toast-b")
      expect(page).to have_css("#generic-toast-f")
    end
    expect_browser_console_clean
  end

  it "通知ごとのtimer、永続表示、中央close後の上詰めを独立して扱う" do
    sign_in_through_browser(create_system_test_user)
    page.execute_script(<<~JAVASCRIPT)
      const timed = document.createElement('div')
      timed.id = 'timed-notice-stack'
      timed.dataset.noticeSurfaceContainer = 'true'
      timed.className = 'fixed top-4 right-4 flex flex-col gap-3 w-96'
      document.body.appendChild(timed)

      const manual = document.createElement('div')
      manual.id = 'manual-notice-stack'
      manual.dataset.noticeSurfaceContainer = 'true'
      manual.className = 'fixed top-4 left-4 flex flex-col gap-3 w-96'
      document.body.appendChild(manual)
    JAVASCRIPT

    append_notice(
      target: "timed-notice-stack",
      message: "短時間の通知A",
      auto_dismiss: true,
      auto_dismiss_delay: 80,
      surface_id: "timed-a"
    )
    append_notice(
      target: "timed-notice-stack",
      message: "長時間の通知B",
      auto_dismiss: true,
      auto_dismiss_delay: 800,
      surface_id: "timed-b"
    )
    append_notice(
      target: "timed-notice-stack",
      message: "永続通知C",
      auto_dismiss: false,
      surface_id: "persistent-c"
    )

    expect(page).to have_no_css("#timed-a", visible: :all)
    aggregate_failures do
      expect(page).to have_css("#timed-b")
      expect(page).to have_css("#persistent-c")
    end
    expect(page).to have_no_css("#timed-b", visible: :all)
    expect(page).to have_css("#persistent-c")

    %w[d e f].each do |suffix|
      append_notice(
        target: "manual-notice-stack",
        message: "手動通知#{suffix.upcase}",
        dismissible: true,
        auto_dismiss: false,
        surface_id: "manual-#{suffix}"
      )
    end
    manual_f_top_before = surface_rect("#manual-f").fetch("top")
    page.execute_script(<<~JAVASCRIPT)
      const button = document.querySelector('#manual-e button[data-action="click->notice-surface#close"]')
      button.click()
      button.click()
    JAVASCRIPT

    expect(page).to have_no_css("#manual-e", visible: :all)
    manual_d_rect = surface_rect("#manual-d")
    manual_f_rect = surface_rect("#manual-f")

    aggregate_failures do
      expect(manual_f_rect.fetch("top")).to be < manual_f_top_before
      expect(manual_f_rect.fetch("top")).to be >= manual_d_rect.fetch("bottom")
      expect(page).to have_css("#persistent-c")
    end
    expect_browser_console_clean
  end

  it "Stimulus再接続後もauto-dismiss timerを一つだけ再開する" do
    sign_in_through_browser(create_system_test_user)
    append_notice(
      target: "toast-stream",
      message: "再接続される通知",
      auto_dismiss: true,
      auto_dismiss_delay: 300,
      remove_before_cache: false,
      surface_id: "reconnected-toast"
    )
    wait_for_surface_controller("#reconnected-toast")

    disconnected_and_reconnected = page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[arguments.length - 1]
      const element = document.getElementById('reconnected-toast')
      const container = document.getElementById('toast-stream')
      const deadline = window.performance.now() + 3000
      element.remove()

      const waitForDisconnect = () => {
        const connected = (window.Stimulus?.controllers || []).some((controller) => controller.element === element)
        if (!connected) {
          container.appendChild(element)
          waitForReconnect()
          return
        }
        if (window.performance.now() >= deadline) {
          done(false)
          return
        }
        window.setTimeout(waitForDisconnect, 25)
      }

      const waitForReconnect = () => {
        const connected = (window.Stimulus?.controllers || []).some((controller) => controller.element === element)
        if (connected) {
          done(true)
          return
        }
        if (window.performance.now() >= deadline) {
          done(false)
          return
        }
        window.setTimeout(waitForReconnect, 25)
      }

      waitForDisconnect()
    JAVASCRIPT

    expect(disconnected_and_reconnected).to be(true)
    expect(page).to have_no_css("#reconnected-toast", visible: :all, wait: 1.5)
    expect_browser_console_clean
  end

  it "設定保存のTurbo flashを既存toastの後ろへ追加する" do
    sign_in_through_browser(create_system_test_user(theme_preference: "system"))
    visit settings_path
    append_notice(
      target: "toast-stream",
      message: "保存前から残る通知",
      auto_dismiss: false,
      remove_before_cache: true,
      surface_id: "existing-toast"
    )

    find("label[for='theme_preference_light']").click

    expect(page).to have_css("#existing-toast", text: "保存前から残る通知")
    expect(page).to have_css(
      "#toast-stream [data-controller~='notice-surface']",
      text: I18n.t("flash.settings.update_success")
    )
    messages = page.evaluate_script(<<~JAVASCRIPT)
      Array.from(document.querySelectorAll('#flash [data-controller~="notice-surface"]')).map((element) => element.textContent)
    JAVASCRIPT

    aggregate_failures do
      expect(messages.first).to include("保存前から残る通知")
      expect(messages.last).to include(I18n.t("flash.settings.update_success"))
      expect(page).to have_css("[data-notice-surface-container]", count: 1)
    end
    expect_browser_console_clean
  end

  it "実Turbo遷移とcache復帰で古いtoastを復活させない" do
    sign_in_through_browser(create_system_test_user)
    append_notice(
      target: "toast-stream",
      message: "cache前に削除する通知",
      auto_dismiss: false,
      remove_before_cache: true,
      surface_id: "turbo-cache-toast"
    )

    find("a[href='#{settings_path}']", match: :first).click
    expect(page).to have_current_path(settings_path, ignore_query: true)
    page.go_back
    expect(page).to have_current_path(receipts_path, ignore_query: true)

    expect(page).to have_no_css("#turbo-cache-toast", visible: :all)
    expect_browser_console_clean
  end

  it "390pxの共通stackで最新5件を残しTurbo cache前に全件削除する", :mobile do
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

      ;(async () => {
        for (let index = 1; index <= 6; index += 1) {
          appendNotice(stream, `dynamic-toast-${index}`, `toast-${index}`)
          await new Promise((resolve) => window.setTimeout(resolve, 25))
        }
        done(true)
      })()
    JAVASCRIPT

    expect(page).to have_css("#flash [data-controller~='notice-surface']", count: 5)
    expect(page).not_to have_css("#dynamic-toast-1")
    expect(page).to have_css("#dynamic-toast-6")

    visible_ids = page.evaluate_script(<<~JAVASCRIPT)
      Array.from(document.querySelectorAll('#flash [data-controller~="notice-surface"]')).map((element) => element.id)
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
