# frozen_string_literal: true

require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "画像読み込み失敗時の実Chromeフォールバック", type: :system, mobile: true do
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

  def attach_fixture(attachment, filename: "receipt_sample.jpg")
    attachment.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/receipt_sample.jpg")),
      filename:,
      content_type: "image/jpeg"
    )
  end

  def delete_stored_file(attachment)
    attachment.blob.service.delete(attachment.blob.key)
  end

  def open_receipt_image
    click_button I18n.t("shared.receipt_image_card.show_image")
  end

  def expect_no_unexpected_console_errors
    unexpected = page.driver.browser.logs.get(:browser).select do |entry|
      next false unless entry.level == "SEVERE"

      expected_missing_image = entry.message.include?("/rails/active_storage/") && entry.message.include?("404")
      !expected_missing_image && !blocked_external_font_entry?(entry)
    end

    expect(unexpected.map(&:message)).to be_empty
  end

  it "390pxで欠損avatar/receiptを隠し、正常画像と新しいobject URLへ復帰する" do
    user = create_system_test_user(name: "画像確認ユーザー")
    attach_fixture(user.avatar, filename: "avatar.jpg")
    missing_receipt = create(:receipt, :completed, :with_image, user:)
    normal_receipt = create(:receipt, :completed, :with_image, user:)
    undecodable_receipt = create(:receipt, :completed, :with_image, user:)
    empty_receipt = create(:receipt, :completed, user:)
    delete_stored_file(user.avatar)
    delete_stored_file(missing_receipt.image)
    delete_stored_file(undecodable_receipt.image)
    undecodable_receipt.image.blob.service.upload(
      undecodable_receipt.image.blob.key,
      StringIO.new("not an image")
    )

    sign_in_through_browser(user)
    expect(page.evaluate_script("window.innerWidth")).to eq(390)

    visit settings_path
    wait_for_stimulus_controller("image-load-state")
    expect(page).to have_css("[data-avatar-fallback]:not(.hidden)", text: "画", minimum: 2)
    expect(page).to have_no_css("img[data-avatar-image]:not(.hidden)")

    visit receipt_path(missing_receipt)
    wait_for_stimulus_controller("receipt-image-card")
    open_receipt_image
    expect(page).to have_content(I18n.t("shared.receipt_image_card.unavailable"))
    expect(page).to have_css("[data-receipt-image-card-target~='previewTrigger'][disabled]", visible: :all)
    missing_preview_trigger = find("[data-receipt-image-card-target~='previewTrigger']", visible: :all)
    missing_download = find("[data-receipt-image-card-target~='download']", visible: :all)
    expect(missing_preview_trigger["aria-label"]).to eq(I18n.t("shared.receipt_image_card.unavailable"))
    expect(missing_download.evaluate_script("window.getComputedStyle(this).display")).to eq("none")
    expect(missing_download.evaluate_script("this.hidden")).to be(true)
    expect(page).to have_no_link(I18n.t("shared.receipt_image_card.download"))
    expect(page).to have_no_css("img[data-receipt-image-card-target~='previewImage']:not(.hidden)")

    page.execute_script("Turbo.visit(arguments[0])", receipt_path(normal_receipt))
    expect(page).to have_current_path(receipt_path(normal_receipt), ignore_query: true)
    wait_for_stimulus_controller("image-load-state")
    open_receipt_image
    expect(page).to have_css("img[data-receipt-image-card-target~='previewImage']:not(.hidden)")
    expect(page).to have_css("[data-receipt-image-card-target~='previewTrigger']:not([disabled])")
    expect(page).to have_link(I18n.t("shared.receipt_image_card.download"))
    normal_preview_trigger = find("[data-receipt-image-card-target~='previewTrigger']")
    normal_download = find("[data-receipt-image-card-target~='download']")
    expect(normal_preview_trigger["aria-label"]).to eq(I18n.t("shared.receipt_image_card.full_preview_aria"))
    expect(normal_download.evaluate_script("window.getComputedStyle(this).display")).not_to eq("none")
    expect(normal_download.evaluate_script("this.hidden")).to be(false)
    find("[data-receipt-image-card-target~='previewTrigger']").click
    expect(page).to have_css("[data-receipt-image-card-target~='modal']:not(.hidden)")
    expect(page).to have_css("img[data-receipt-image-card-target~='modalImage']:not(.hidden)")
    click_button I18n.t("shared.receipt_image_card.close_preview_aria")

    page.go_back
    expect(page).to have_current_path(receipt_path(missing_receipt), ignore_query: true)
    open_receipt_image
    expect(page).to have_content(I18n.t("shared.receipt_image_card.unavailable"))
    expect(page).to have_css("[data-receipt-image-card-target~='previewTrigger'][disabled]", visible: :all)
    restored_preview_trigger = find("[data-receipt-image-card-target~='previewTrigger']", visible: :all)
    restored_download = find("[data-receipt-image-card-target~='download']", visible: :all)
    expect(restored_preview_trigger["aria-label"]).to eq(I18n.t("shared.receipt_image_card.unavailable"))
    expect(restored_download.evaluate_script("window.getComputedStyle(this).display")).to eq("none")
    expect(restored_download.evaluate_script("this.hidden")).to be(true)
    expect(page).to have_no_link(I18n.t("shared.receipt_image_card.download"))

    visit receipt_path(undecodable_receipt)
    wait_for_stimulus_controller("image-load-state")
    open_receipt_image
    expect(page).to have_content(I18n.t("shared.receipt_image_card.unavailable"))
    expect(page).to have_css("[data-receipt-image-card-target~='previewTrigger'][disabled]", visible: :all)
    expect(page).to have_no_link(I18n.t("shared.receipt_image_card.download"))

    visit receipt_path(empty_receipt)
    expect(page).to have_content(I18n.t("receipts.show.image_empty"))
    expect(page).to have_no_content(I18n.t("shared.receipt_image_card.unavailable"))

    visit edit_receipt_path(missing_receipt)
    wait_for_stimulus_controller("image-load-state")
    find("input[name='receipt[image]']", visible: :all).attach_file(
      Rails.root.join("spec/fixtures/files/receipt_sample.jpg")
    )
    open_receipt_image
    expect(page).to have_css("img[data-receipt-image-card-target~='previewImage']:not(.hidden)")
    expect(page).to have_css("[data-receipt-image-card-target~='previewTrigger']:not([disabled])")

    visit settings_account_path
    wait_for_stimulus_controller("avatar-preview")
    find("input[name='user[avatar]']", visible: :all).attach_file(
      Rails.root.join("spec/fixtures/files/receipt_sample.jpg")
    )
    expect(page).to have_css("img[data-avatar-image]:not(.hidden)")

    aggregate_failures do
      expect(page.evaluate_script("window.innerWidth")).to eq(390)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      expect(page.evaluate_script("[...document.images].every((image) => image.classList.contains('hidden') || image.naturalWidth > 0)")).to be(true)
    end
    expect_no_unexpected_console_errors
  end

  it "390pxで欠損したお知らせ画像をpublic/admin/edit画面から隠す" do
    public_announcement = create(:announcement, :published, image_alt_text: "公開画像")
    normal_announcement = create(:announcement, :published, image_alt_text: "正常な公開画像")
    empty_announcement = create(:announcement, :published)
    draft_announcement = create(:announcement, status: "draft", image_alt_text: "下書き画像")
    empty_draft = create(:announcement, status: "draft")
    attach_fixture(public_announcement.image, filename: "public-announcement.jpg")
    attach_fixture(normal_announcement.image, filename: "normal-announcement.jpg")
    attach_fixture(draft_announcement.image, filename: "draft-announcement.jpg")
    delete_stored_file(public_announcement.image)
    delete_stored_file(draft_announcement.image)

    visit announcement_path(public_announcement)
    wait_for_stimulus_controller("image-load-state")
    expect(page).to have_content(I18n.t("announcements.image.unavailable"))
    expect(page).to have_no_css("img[alt='公開画像']:not(.hidden)")

    page.execute_script("Turbo.visit(arguments[0])", announcement_path(normal_announcement))
    expect(page).to have_current_path(announcement_path(normal_announcement), ignore_query: true)
    wait_for_stimulus_controller("image-load-state")
    expect(page).to have_css("img[alt='正常な公開画像']:not(.hidden)")
    expect(page).to have_no_content(I18n.t("announcements.image.unavailable"))

    page.go_back
    expect(page).to have_current_path(announcement_path(public_announcement), ignore_query: true)
    expect(page).to have_content(I18n.t("announcements.image.unavailable"))
    expect(page).to have_no_css("img[alt='公開画像']:not(.hidden)")

    visit announcement_path(empty_announcement)
    expect(page).to have_no_content(I18n.t("announcements.image.unavailable"))
    expect(page).to have_no_css("[data-controller~='image-load-state']")

    admin = create_system_test_user(name: "お知らせ管理者", admin: true)
    sign_in_through_browser(admin)

    visit admin_announcement_path(empty_draft)
    expect(page).to have_content(I18n.t("admin.announcements.show.image_empty"))
    expect(page).to have_no_content(I18n.t("announcements.image.unavailable"))

    visit edit_admin_announcement_path(empty_draft)
    wait_for_stimulus_controller("image-load-state")
    expect(page).to have_content(I18n.t("admin.announcements.form.image_empty"))
    expect(page).to have_no_content(I18n.t("announcements.image.unavailable"))
    expect(page).to have_no_css("input[name='announcement[remove_image]']")

    visit admin_announcement_path(draft_announcement)
    wait_for_stimulus_controller("image-load-state")
    expect(page).to have_content(I18n.t("announcements.image.unavailable"))
    expect(page).to have_no_css("img[alt='下書き画像']:not(.hidden)")

    visit edit_admin_announcement_path(draft_announcement)
    wait_for_stimulus_controller("image-load-state")
    expect(page).to have_content(I18n.t("announcements.image.unavailable"))
    expect(page).to have_no_css("img[data-attachment-preview-target~='image']:not(.hidden)")
    expect(page).to have_no_content(I18n.t("admin.announcements.form.image_empty"))

    remove_checkbox = find("input[name='announcement[remove_image]']", visible: :all)
    remove_checkbox.set(true)
    expect(page).to have_content(I18n.t("admin.announcements.form.image_empty"))
    expect(page).to have_no_content(I18n.t("announcements.image.unavailable"))

    remove_checkbox.set(false)
    expect(page).to have_content(I18n.t("announcements.image.unavailable"))
    expect(page).to have_no_content(I18n.t("admin.announcements.form.image_empty"))

    find("input[name='announcement[image]']", visible: :all).attach_file(
      Rails.root.join("spec/fixtures/files/receipt_sample.jpg")
    )
    expect(page).to have_css("img[data-attachment-preview-target~='image']:not(.hidden)")
    expect(page).to have_no_content(I18n.t("announcements.image.unavailable"))

    aggregate_failures do
      expect(page.evaluate_script("window.innerWidth")).to eq(390)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      expect(page.evaluate_script("[...document.images].every((image) => image.classList.contains('hidden') || image.naturalWidth > 0)")).to be(true)
    end
    expect_no_unexpected_console_errors
  end
end
