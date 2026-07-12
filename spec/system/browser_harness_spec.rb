require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "実Chrome system test harness", type: :system do
  it "Stimulusを実行し、実ログイン後に完了済みレシートを表示する" do
    user = create_system_test_user
    create(
      :receipt,
      :completed,
      user: user,
      store_name: "システムテスト店",
      purchased_at: Time.zone.local(2026, 7, 12, 12, 0, 0)
    )
    queue_adapter = ActiveJob::Base.queue_adapter
    expect(queue_adapter).to respond_to(:enqueued_jobs)
    queued_job_count = queue_adapter.enqueued_jobs.size

    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"

    wait_for_stimulus_controller("password-reveal")
    reveal_button = find("[data-password-reveal-target='button']")
    reveal_button.click

    expect(page).to have_css("#user_password[type='text']")
    expect(reveal_button["aria-pressed"]).to eq("true")

    click_button I18n.t("auth.sessions.submit")

    expect(page).to have_current_path(receipts_path, ignore_query: true)
    expect(page).to have_content("システムテスト店")
    wait_for_stimulus_controller("receipt-processing-sync")
    expect(queue_adapter.enqueued_jobs.size).to eq(queued_job_count)
    expect_browser_console_clean
  end
end
