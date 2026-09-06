require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "画像確認リンクの実Chrome回帰", type: :system do
  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  [ [ 1440, 1000 ], [ 390, 844 ] ].each do |width, height|
    it "#{width}pxで初回・同一hash・履歴移動後も画像を確認できる", screen_size: [ width, height ] do
      page.driver.browser.execute_cdp(
        "Emulation.setDeviceMetricsOverride",
        width:,
        height:,
        deviceScaleFactor: 1,
        mobile: width == 390
      )
      user = create_system_test_user
      receipt = create(:receipt, :review_needed, :with_image, user:, review_reasons: [ "ocr_low_confidence" ])
      visit new_user_session_path
      fill_in "user_email", with: user.email
      fill_in "user_password", with: "password"
      click_button I18n.t("auth.sessions.submit")
      expect(page).to have_current_path(receipts_path, ignore_query: true)
      visit edit_receipt_path(receipt)
      wait_for_stimulus_controller("receipt-image-card")
      wait_for_stimulus_controller("image-load-state")
      find("[data-receipt-warning-notes-card] summary").click
      page.execute_script(<<~JAVASCRIPT)
        window.reviewCacheEvents = 0
        document.addEventListener('turbo:before-cache', () => { window.reviewCacheEvents += 1 })
      JAVASCRIPT

      link_selector = "a[data-review-reason-target-link][data-review-reason-code='ocr_low_confidence']"
      find(link_selector).click
      expect(page).to have_css("img[data-receipt-image-card-target~='previewImage']:not(.hidden)")
      expect(page).to have_css("[data-receipt-image-card-target~='previewTrigger']:not([disabled])")
      expect(page.evaluate_script("window.location.hash")).to eq("#receipt-section-image-preview")
      history_length = page.evaluate_script("window.history.length")

      find(link_selector).click
      expect(page.evaluate_script("window.history.length")).to eq(history_length)
      expect(page.evaluate_script("window.reviewCacheEvents")).to eq(0)
      find("[data-receipt-image-card-target~='previewTrigger']").click
      expect(page).to have_css("[data-receipt-image-card-target~='modal']:not(.hidden)")
      expect(page).to have_css("img[data-receipt-image-card-target~='modalImage']:not(.hidden)")
      click_button I18n.t("shared.receipt_image_card.close_preview_aria")

      page.go_back
      expect(page).to have_current_path(edit_receipt_path(receipt), ignore_query: true)
      page.go_forward
      expect(page).to have_css("img[data-receipt-image-card-target~='previewImage']:not(.hidden)")
      expect(page).to have_css("[data-receipt-image-card-target~='previewTrigger']:not([disabled])")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      expect(page.evaluate_script("window.innerWidth")).to eq(width)
      expect_browser_console_clean
    end
  end
end
