require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "未保存画像の離脱確認", type: :system do
  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  it "画像選択時だけ共通dialogでTurbo離脱を確認し、離脱後の戻る操作では選択画像を復元しない" do
    user = create_system_test_user
    ENV["RECEIPT_OCR_ENABLED"] = "true"
    sign_in_through_browser(user)
    visit new_upload_receipts_path
    wait_for_stimulus_controller("upload-guard")
    find("input[data-receipt-upload-target='cameraInput']", visible: :all).attach_file(
      Rails.root.join("spec/fixtures/files/receipt_sample.jpg")
    )
    back_link = find("a[href='#{select_input_method_receipts_path}']")
    back_link.click

    dialog = find("dialog[data-confirm-dialog][open]")
    expect(dialog).to have_text(I18n.t("upload_guard.message"))
    expect(page).to have_current_path(new_upload_receipts_path, ignore_query: true)
    dialog.find("[data-confirm-dialog-cancel][type='button']").click
    expect(page).not_to have_css("dialog[data-confirm-dialog][open]")
    expect(page.evaluate_script("document.activeElement.getAttribute('href')")).to eq(select_input_method_receipts_path)
    expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=cameraInput]').files.length")).to eq(1)

    back_link.click
    find("dialog[data-confirm-dialog][open] [data-confirm-dialog-confirm]").click
    expect(page).to have_current_path(select_input_method_receipts_path, ignore_query: true)
    page.go_back
    expect(page).to have_current_path(new_upload_receipts_path, ignore_query: true)
    wait_for_stimulus_controller("upload-guard")
    expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=cameraInput]').files.length")).to eq(0)
    expect(page).not_to have_css("[data-receipt-upload-target='preview'][src]", visible: :all)
    find("a[href='#{select_input_method_receipts_path}']").click
    expect(page).to have_current_path(select_input_method_receipts_path, ignore_query: true)
    expect(page).not_to have_css("dialog[data-confirm-dialog][open]")
    expect(user.receipts.count).to eq(0)
    expect_browser_console_clean
  end

  it "プロフィールの新しい画像は離脱を保護し、画像なしの通常入力は対象にしない", :mobile do
    user = create_system_test_user
    sign_in_through_browser(user)
    visit settings_account_path
    wait_for_stimulus_controller("upload-guard")
    attach_file "user_avatar", Rails.root.join("spec/fixtures/files/receipt_sample.jpg")
    find("#user_name").click
    expect(page.evaluate_script("document.querySelector('#user_avatar').files.length")).to eq(1)
    expect(page.evaluate_script(<<~JAVASCRIPT)).to be(true)
      window.Stimulus.controllers.find(controller => controller.identifier === 'upload-guard').needsConfirmation()
    JAVASCRIPT
    expect(page.evaluate_script(<<~JAVASCRIPT)).to be(true)
      (() => {
        const event = new Event('beforeunload', { cancelable: true })
        window.dispatchEvent(event)
        return event.defaultPrevented
      })()
    JAVASCRIPT
    find("form[data-controller~=upload-guard] a[href='#{settings_path}']").click
    expect(page).to have_css("dialog[data-confirm-dialog][open]")
    find("dialog[data-confirm-dialog][open] [data-confirm-dialog-cancel][type=button]").click
    expect(page.evaluate_script("document.querySelector('#user_avatar').files.length")).to eq(1)
    # ChromeDriverの標準離脱dialog自動処理と分け、実表示は実ブラウザで確認する。
    page.refresh
    wait_for_stimulus_controller("upload-guard")
    expect(page.evaluate_script("document.querySelector('#user_avatar').files.length")).to eq(0)

    fill_in "user_name", with: "Synthetic unsaved name"
    page.refresh
    expect(page).to have_field("user_name", with: user.name)
    expect(user.reload.avatar).not_to be_attached
    expect_browser_console_clean
  end

  it "別ページへの履歴移動で選択画像を破棄し、進む操作でプレビューを復元しない" do
    user = create_system_test_user
    ENV["RECEIPT_OCR_ENABLED"] = "true"
    sign_in_through_browser(user)
    visit select_input_method_receipts_path
    find("a[href='#{new_upload_receipts_path}']").click
    expect(page).to have_current_path(new_upload_receipts_path, ignore_query: true)
    wait_for_stimulus_controller("upload-guard")
    find("input[data-receipt-upload-target='cameraInput']", visible: :all).attach_file(
      Rails.root.join("spec/fixtures/files/receipt_sample.jpg")
    )
    expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=cameraInput]').files.length")).to eq(1)
    page.go_back
    expect(page).to have_current_path(select_input_method_receipts_path, ignore_query: true)
    expect(page).not_to have_css('form[data-controller~="upload-guard"]')
    page.go_forward
    expect(page).to have_current_path(new_upload_receipts_path, ignore_query: true)
    wait_for_stimulus_controller("upload-guard")
    expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=cameraInput]').files.length")).to eq(0)
    expect(page).not_to have_css("[data-receipt-upload-target='preview'][src]", visible: :all)
    expect(user.receipts.count).to eq(0)
    expect_browser_console_clean
  end
end
