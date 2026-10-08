require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "画像プレビューと画面内移動の実Chrome回帰", type: :system do
  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  def set_viewport(width, height)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width:,
      height:,
      deviceScaleFactor: 1,
      mobile: width < 768
    )
  end

  def sign_in_and_edit(user, receipt)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    wait_for_stimulus_controller("receipt-image-card")
    all("[data-receipt-notes-summary]").each do |summary|
      details = summary.find(:xpath, "..")
      expect(details).to match_selector("details[data-collapsible-enhanced='true']")
      summary.click
      expect(details).to match_selector("details[open][data-collapsible-open='true']")
      wait_for_visual_motion_to_finish(details)
    end
  end

  def wait_for_visual_motion_to_finish(element)
    settled = page.evaluate_async_script(<<~JAVASCRIPT, element, Capybara.default_max_wait_time * 1000)
      const target = arguments[0]
      const timeoutMilliseconds = arguments[1]
      const done = arguments[arguments.length - 1]
      let completed = false

      const finish = (result) => {
        if (completed) return

        completed = true
        done(result)
      }

      window.setTimeout(() => finish(false), timeoutMilliseconds)
      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(() => {
          const animations = target.getAnimations({ subtree: true })
          const fontsReady = document.fonts?.ready || Promise.resolve()
          Promise.all([
            fontsReady,
            ...animations.map((animation) => animation.finished.catch(() => undefined))
          ])
            .then(() => finish(true))
        })
      })
    JAVASCRIPT

    expect(settled).to be(true), "CSS motion did not finish"
  end

  def set_preview_open(open)
    toggle = find("[data-receipt-image-card-target~='toggleButton']")
    toggle.click unless toggle["aria-expanded"] == open.to_s
    expect(toggle["aria-expanded"]).to eq(open.to_s)
  end

  def expect_loaded_image(target = "previewImage")
    selector = "img[data-receipt-image-card-target~='#{target}']"
    expect(page).to have_css("#{selector}:not(.hidden)")
    image = find(selector)
    state = image.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const bounds = this.getBoundingClientRect()
        const style = getComputedStyle(this)
        return {
          loaded: this.complete && this.naturalWidth > 0 && this.naturalHeight > 0,
          displayed: style.display !== 'none' && style.visibility !== 'hidden',
          hasArea: bounds.width > 0 && bounds.height > 0
        }
      })()
    JAVASCRIPT
    expect(state).to eq("loaded" => true, "displayed" => true, "hasArea" => true)
  end

  def expect_usable_preview
    expect_loaded_image
    expect(page).to have_css("[data-receipt-image-card-target~='previewTrigger']:not([disabled])[aria-disabled='false']")
    expect(page).to have_css("[data-receipt-image-card-target~='previewImage']", visible: true)
  end

  def expect_usable_modal
    find("[data-receipt-image-card-target~='previewTrigger']").click
    expect(page).to have_css("[data-receipt-image-card-target~='modal'][aria-hidden='false']")
    expect_loaded_image("modalImage")
    page.send_keys(:escape)
    expect(page).to have_css("[data-receipt-image-card-target~='modal'][aria-hidden='true']", visible: :all)
    expect(page.evaluate_script("document.body.classList.contains('overflow-hidden')")).to be(false)
  end

  def remember_preview
    page.execute_script(<<~JAVASCRIPT)
      if (!window.imageLifecycle) {
        document.addEventListener('turbo:before-cache', () => { window.imageLifecycle.cacheEvents += 1 })
      }
      window.imageLifecycle = {
        form: document.querySelector('[data-controller~="receipt-form"]'),
        image: document.querySelector('[data-receipt-image-card-target~="previewImage"]'),
        file: document.querySelector('input[name="receipt[image]"]')?.files[0],
        cacheEvents: 0
      }
    JAVASCRIPT
  end

  def expect_same_preview(file_selected: false, cache_events: 0)
    state = page.evaluate_script(<<~JAVASCRIPT)
      (() => ({
        sameForm: window.imageLifecycle.form === document.querySelector('[data-controller~="receipt-form"]'),
        sameImage: window.imageLifecycle.image === document.querySelector('[data-receipt-image-card-target~="previewImage"]'),
        sameFile: window.imageLifecycle.file === document.querySelector('input[name="receipt[image]"]')?.files[0],
        fileCount: document.querySelector('input[name="receipt[image]"]')?.files.length,
        cacheEvents: window.imageLifecycle.cacheEvents
      }))()
    JAVASCRIPT
    expect(state).to eq(
      "sameForm" => true, "sameImage" => true, "sameFile" => true,
      "fileCount" => file_selected ? 1 : 0, "cacheEvents" => cache_events
    )
  end

  def follow_history(direction, hash)
    result = page.evaluate_async_script(<<~JAVASCRIPT, direction, Capybara.default_max_wait_time * 1000)
      const direction = arguments[0]
      const timeoutMilliseconds = arguments[1]
      const done = arguments[arguments.length - 1]
      const finish = () => {
        window.clearTimeout(timer)
        requestAnimationFrame(() => done(window.location.hash))
      }
      const timer = window.setTimeout(() => {
        window.removeEventListener('hashchange', finish)
        done('timed out')
      }, timeoutMilliseconds)
      window.addEventListener('hashchange', finish, { once: true })
      window.history.go(direction)
    JAVASCRIPT
    expect(result).to eq(hash)
  end

  def cache_without_leaving
    result = page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[arguments.length - 1]
      Turbo.session.view.cacheSnapshot().then(() => done(true), () => done(false))
    JAVASCRIPT
    expect(result).to be(true)
  end

  def select_receipt_image
    find("input[name='receipt[image]']", visible: :all).attach_file(
      Rails.root.join("spec/fixtures/files/receipt_sample.jpg")
    )
  end

  [ [ 1440, 1000, "light" ], [ 390, 844, "dark" ] ].each do |width, height, theme|
    it "#{width}pxで金額確認の前後に展開しても画像と履歴を維持する" do
      set_viewport(width, height)
      user = create_system_test_user(theme_preference: theme)
      receipt = create(:receipt, :review_needed, :with_image, user:, review_reasons: [ "price_tax_inclusion_uncertain" ])
      sign_in_and_edit(user, receipt)
      expect(page).to have_css("html[data-theme='#{theme}']")
      set_preview_open(false)
      remember_preview

      link = find("a[data-review-reason-code='price_tax_inclusion_uncertain']")
      link.click
      expect(page.evaluate_script("window.location.hash")).to eq("#receipt-section-amount-summary")
      set_preview_open(true)
      expect_usable_preview
      expect_same_preview

      follow_history(-1, "")
      expect_usable_preview
      link.click
      expect_usable_preview
      expect_same_preview
      history_length = page.evaluate_script("history.length")
      link.send_keys(:enter)
      expect(page.evaluate_script("history.length")).to eq(history_length)
      expect_usable_modal
      expect_same_preview
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      expect_browser_console_clean
    end
  end

  it "8種類の確認先をキーボードで連続操作しても選択画像と未保存入力を保持する" do
    user = create_system_test_user
    receipt = create(:receipt, :review_needed, :with_image, user:, review_reasons: %w[
      store_name_uncertain items_missing discount_data_incomplete payment_method_uncertain
      price_tax_inclusion_uncertain ocr_low_confidence
    ])
    item = receipt.receipt_items.create!(
      raw_text: "確認商品", confirmed_name: "確認商品", price: 100, quantity: 1,
      quantity_unit_code: "each", line_total: 100, tax_rate: 0,
      needs_review: true, review_reasons: [ "item_tax_rate_uncertain" ]
    )
    adjustment = create(:receipt_adjustment, receipt:, needs_review: true, review_reasons: [ "adjustment_uncertain" ])
    sign_in_and_edit(user, receipt)
    set_preview_open(true)
    select_receipt_image
    expect_usable_preview
    fill_in "receipt_store_name", with: "未保存の確認店"
    remember_preview

    targets = [
      ReceiptsHelper::RECEIPT_REVIEW_TARGET_BASIC_INFO,
      ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEMS,
      ReceiptsHelper::RECEIPT_REVIEW_TARGET_ADJUSTMENTS,
      ReceiptsHelper::RECEIPT_REVIEW_TARGET_PAYMENTS,
      ReceiptsHelper::RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
      ReceiptsHelper::RECEIPT_REVIEW_TARGET_IMAGE_PREVIEW,
      "#{ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEM_ID_PREFIX}#{item.id}",
      "#{ReceiptsHelper::RECEIPT_REVIEW_TARGET_ADJUSTMENT_ID_PREFIX}#{adjustment.id}"
    ]
    targets.each do |target|
      find("a[data-review-reason-anchor-target='#{target}']", match: :first).send_keys(:enter)
      expect(page).to have_current_path(edit_receipt_path(receipt)) { |url| url.fragment == target }
      expect_usable_preview
      expect_same_preview(file_selected: true)
      expect(page).to have_field("receipt_store_name", with: "未保存の確認店")
    end

    follow_history(-1, "##{targets[-2]}")
    expect_same_preview(file_selected: true)
    follow_history(1, "##{targets[-1]}")
    expect_same_preview(file_selected: true)
    expect_usable_modal
    expect(page).to have_field("receipt_store_name", with: "未保存の確認店")
    expect_browser_console_clean
  end

  it "画面を置換しないキャッシュ準備の反復後も保存済み画像と選択画像を操作できる" do
    user = create_system_test_user
    receipt = create(:receipt, :completed, :with_image, user:)
    sign_in_and_edit(user, receipt)
    set_preview_open(true)
    expect_usable_preview
    remember_preview

    cache_without_leaving
    cache_without_leaving
    expect_usable_preview
    expect_same_preview(cache_events: 2)
    expect_usable_modal

    select_receipt_image
    expect_usable_preview
    remember_preview
    cache_without_leaving
    expect_usable_preview
    expect_same_preview(file_selected: true, cache_events: 1)
    expect_usable_modal
    expect_browser_console_clean
  end

  it "画像未添付のフォームでも選択後の再接続とキャッシュ準備で画像を失わない" do
    user = create_system_test_user
    receipt = create(:receipt, :completed, user:)
    sign_in_and_edit(user, receipt)
    select_receipt_image
    expect_loaded_image
    reconnected = page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[arguments.length - 1]
      const card = document.querySelector('[data-controller~="receipt-image-card"]')
      const parent = card.parentNode
      const next = card.nextSibling
      card.remove()
      requestAnimationFrame(() => {
        parent.insertBefore(card, next)
        requestAnimationFrame(() => done(card.isConnected))
      })
    JAVASCRIPT
    expect(reconnected).to be(true)
    expect_loaded_image
    expect(page.evaluate_script("document.querySelector('input[name=\"receipt[image]\"]').files.length")).to eq(1)
    cache_without_leaving
    expect_loaded_image
    expect_browser_console_clean
  end

  it "別画面から複製キャッシュへ戻ると選択Fileの有無に応じて画像を復元する" do
    user = create_system_test_user
    receipt = create(:receipt, :completed, :with_image, user:)
    sign_in_and_edit(user, receipt)
    set_preview_open(true)
    select_receipt_image
    expect_usable_preview
    fill_in "receipt_store_name", with: "キャッシュ復元する未保存店名"
    remember_preview
    page.execute_script("window.imageLifecycle.selectedSource = window.imageLifecycle.image.src")

    find("a[href='#{settings_path}']", visible: true).click
    expect(page).to have_current_path(settings_path)
    expect_browser_console_clean
    page.go_back
    expect(page).to have_current_path(edit_receipt_path(receipt))
    wait_for_stimulus_controller("receipt-form")
    wait_for_stimulus_controller("receipt-image-card")
    expect(page).to have_field("receipt_store_name", with: "キャッシュ復元する未保存店名")
    set_preview_open(true)
    expect_usable_preview

    restored = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const card = document.querySelector('[data-controller~="receipt-image-card"]')
        const image = card.querySelector('[data-receipt-image-card-target~="previewImage"]')
        const file = card.querySelector('input[type="file"]').files[0]
        const original = new URL(card.dataset.receiptImageCardOriginalSourceValue, location.href).href
        return {
          cloned: image !== window.imageLifecycle.image,
          cached: window.imageLifecycle.cacheEvents > 0,
          sourceRestored: file ? image.src.startsWith('blob:') : image.src === original,
          sourceReplaced: image.src !== window.imageLifecycle.selectedSource
        }
      })()
    JAVASCRIPT
    expect(restored).to eq("cloned" => true, "cached" => true, "sourceRestored" => true, "sourceReplaced" => true)
    expect_usable_modal
    expect_browser_console_clean
  end

  it "選択画像の読み込み前に別画面へ離脱してもキャッシュ画像を復元できる" do
    user = create_system_test_user
    receipt = create(:receipt, :completed, :with_image, user:)
    sign_in_and_edit(user, receipt)
    set_preview_open(true)
    page.execute_script(<<~JAVASCRIPT, settings_path)
      const destination = arguments[0]
      document.querySelector('input[name="receipt[image]"]').addEventListener('change', () => {
        const image = document.querySelector('[data-receipt-image-card-target~="previewImage"]')
        window.leftDuringImageLoad = !image.complete
        Turbo.visit(destination)
      }, { once: true })
    JAVASCRIPT
    select_receipt_image
    expect(page).to have_current_path(settings_path)
    expect(page.evaluate_script("window.leftDuringImageLoad")).to be(true)
    expect_browser_console_clean

    page.go_back
    expect(page).to have_current_path(edit_receipt_path(receipt))
    wait_for_stimulus_controller("receipt-image-card")
    set_preview_open(true)
    expect_usable_preview
    expect_usable_modal
    expect_browser_console_clean
  end

  it "画像差し替えの422再表示では再選択を案内し、再選択するとプレビューが復帰する" do
    user = create_system_test_user
    receipt = create(:receipt, :completed, :with_image, user:)
    sign_in_and_edit(user, receipt)
    select_receipt_image
    page.execute_script("document.querySelector('textarea[name=\"receipt[memo]\"]').value = 'x'.repeat(1001)")
    find("button[type='submit']", text: I18n.t("receipts.form.buttons.save"), match: :first).click
    expect(page).to have_content(I18n.t("shared.receipt_image_card.reselect_image"))
    expect(page.evaluate_script("document.querySelector('input[name=\"receipt[image]\"]').files.length")).to eq(0)
    select_receipt_image
    expect_loaded_image
    cache_without_leaving
    expect_loaded_image
    severe_entries = page.driver.browser.logs.get(:browser).select do |entry|
      entry.level == "SEVERE" && !blocked_external_font_entry?(entry)
    end
    validation_entries, unexpected_entries = severe_entries.partition do |entry|
      entry.message.include?(receipt_path(receipt)) && entry.message.include?("422 (Unprocessable Content)")
    end
    aggregate_failures do
      expect(validation_entries).not_to be_empty
      expect(unexpected_entries.map(&:message)).to be_empty
    end
  end
end
