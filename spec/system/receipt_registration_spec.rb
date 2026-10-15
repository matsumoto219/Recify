require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "レシート新規登録の失敗案内", type: :system do
  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  %w[upload manual].each do |kind|
    it "#{kind}の確定失敗通知を既読にして元の種類の新規フォームを開く", mobile: kind == "manual" do
      user = create_system_test_user
      user.update!(push_notification_enabled: false)
      token = Receipts::Registrations.issue_token(user:, kind:)
      Receipts::Registrations.with_operation(user:, token:, kind:, input: {}) do |operation|
        Receipts::Registrations.report_failure(operation:, reason: "storage_failed")
      end
      notification = user.notifications.find_by!(kind: "receipt_upload_failed")
      sign_in_through_browser(user)
      visit notifications_path

      within("#notification_#{notification.id}") do
        expect(page).to have_text(I18n.t("receipt_registration.notification.title"))
        expect(page).to have_text("storage_failed")
        click_button I18n.t("notifications.item.mark_as_read")
      end

      expect(page).to have_current_path(kind == "manual" ? new_receipt_path : new_upload_receipts_path)
      expect(notification.reload).to be_read
      new_token = find('input[name="receipt_registration_token"]', visible: :all).value
      expect(new_token).to be_present
      expect(new_token).not_to eq(token)
      expect(page).not_to have_css("[data-receipt-registration-mode-value]", visible: :all)
      expect(page.evaluate_script("Array.from(document.querySelectorAll('input[type=file]')).every(input => input.files.length === 0)")).to be(true)
      expect(user.receipts.count).to eq(0)
      expect(user.receipt_registration_operations.count).to eq(1)
      expect_browser_console_clean
    end
  end

  it "開いたフォームの通信エラーだけを既存のエラー表示で案内し、操作IDと選択画像を保持する" do
    user = create_system_test_user
    ENV["RECEIPT_OCR_ENABLED"] = "true"
    sign_in_through_browser(user)
    visit new_upload_receipts_path
    wait_for_stimulus_controller("receipt-registration")
    token = find('input[name="receipt_registration_token"]', visible: :all).value
    find("input[data-receipt-upload-target='cameraInput']", visible: :all).attach_file(
      Rails.root.join("spec/fixtures/files/receipt_sample.jpg")
    )
    # Turboの通信エラーイベントと画面の接続を検証する。実HTTP切断は別の境界検証で扱う。
    page.execute_script(<<~JAVASCRIPT)
      document.querySelector('form[data-controller~="receipt-registration"]').dispatchEvent(
        new CustomEvent('turbo:fetch-request-error', { bubbles: true, detail: { error: new Error('synthetic transport error') } })
      )
    JAVASCRIPT

    within('[data-receipt-registration-target="error"]') do
      expect(page).to have_css('[role="alert"]', text: I18n.t("receipt_registration.transport_unknown"))
    end
    expect(page).to have_field("receipt_registration_token", type: :hidden, with: token, visible: :all)
    expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=cameraInput]').files.length")).to eq(1)
    expect(user.receipt_registration_operations.count).to eq(0)
    expect(user.notifications.count).to eq(0)
    find("a[href='#{select_input_method_receipts_path}']").click
    find("dialog[data-confirm-dialog][open] [data-confirm-dialog-cancel][type=button]").click
    expect(page).to have_current_path(new_upload_receipts_path)
    expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=cameraInput]').files.length")).to eq(1)
    expect_browser_console_clean
  end

  it "選択画像があるフォームから失敗通知を開く移動も共通確認で取り消せる" do
    user = create_system_test_user
    ENV["RECEIPT_OCR_ENABLED"] = "true"
    notification = create(:notification, user:, kind: "receipt_upload_failed", action_path: new_upload_receipts_path)
    sign_in_through_browser(user)
    visit new_upload_receipts_path
    wait_for_stimulus_controller("upload-guard")
    find("input[data-receipt-upload-target='cameraInput']", visible: :all).attach_file(
      Rails.root.join("spec/fixtures/files/receipt_sample.jpg")
    )
    find('[data-notification-dropdown-target="button"]').click
    within("#notifications-dropdown") { find("a[href='#{read_notification_path(notification)}']").click }
    find("dialog[data-confirm-dialog][open] [data-confirm-dialog-cancel][type=button]").click

    expect(page).to have_current_path(new_upload_receipts_path)
    expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=cameraInput]').files.length")).to eq(1)
    expect(user.notifications.count).to eq(1)
    expect(user.receipts.count).to eq(0)
    expect_browser_console_clean
  end
end
