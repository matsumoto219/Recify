require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "ゲスト本登録の実Chrome回帰", type: :system do
  include ActiveSupport::Testing::TimeHelpers

  before do
    ActionMailer::Base.deliveries.clear
    LegalDocuments::Sync.call
  end

  after do
    travel_back
    ActionMailer::Base.deliveries.clear
  end

  def confirmation_token_from(message)
    body = message.html_part&.body&.decoded || message.body.decoded
    match = body.match(/confirmation_token=([^"'&\s]+)/)

    raise "confirmation token was not found in the local test delivery" unless match

    CGI.unescapeHTML(match[1])
  end

  def submit_password_login(email:, password:)
    visit new_user_session_path
    fill_in "user_email", with: email
    fill_in "user_password", with: password
    click_button I18n.t("auth.sessions.submit")
  end

  def start_guest_registration_via_browser(email:, password: "browser-password-123")
    visit new_user_session_path
    click_button I18n.t("auth.sessions.guest.button")
    expect(page).to have_current_path(receipts_path, ignore_query: true)

    guest = User.where(guest: true).order(:id).last
    visit settings_security_path
    within("#guest-registration") do
      fill_in "user_email", with: email
      fill_in "user_password", with: password
      fill_in "user_password_confirmation", with: password
      check "guest_registration_legal_agreement"
      click_button I18n.t("settings.security.guest_registration.submit")
    end

    expect(page).to have_content(I18n.t("settings.security.guest_registration.pending.title"))
    expect(ActionMailer::Base.deliveries.size).to eq(1)

    [ guest, confirmation_token_from(ActionMailer::Base.deliveries.last) ]
  end

  it "同じbrowserでguest本登録を完了し、旧sessionを終了して登録情報で再loginできる" do
    registered_email = "browser-guest-confirmation@example.com"
    registered_password = "browser-password-123"

    visit new_user_session_path
    click_button I18n.t("auth.sessions.guest.button")

    expect(page).to have_current_path(receipts_path, ignore_query: true)
    guest = User.where(guest: true).order(:id).last
    tracked_guest_session = guest.user_sessions.order(:id).last
    session_version_before_confirmation = guest.session_version

    visit settings_security_path
    within("#guest-registration") do
      fill_in "user_email", with: registered_email
      fill_in "user_password", with: registered_password
      fill_in "user_password_confirmation", with: registered_password
      check "guest_registration_legal_agreement"
      click_button I18n.t("settings.security.guest_registration.submit")
    end

    expect(page).to have_current_path(settings_security_path, ignore_query: true)
    expect(page).to have_content(I18n.t("settings.security.guest_registration.pending.title"))
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    token = confirmation_token_from(ActionMailer::Base.deliveries.last)

    visit user_confirmation_path(confirmation_token: token)

    aggregate_failures do
      expect(page).to have_current_path(new_user_session_path, ignore_query: true)
      expect(page).to have_content(I18n.t("flash.users.guest_registration.completed"))
      expect(guest.reload).not_to be_guest
      expect(guest.email).to eq(registered_email)
      expect(guest.unconfirmed_email).to be_nil
      expect(guest.session_version).to eq(session_version_before_confirmation + 1)
      expect(tracked_guest_session.reload.signed_out_at).to be_present
      expect(guest.user_sessions.count).to eq(1)
    end

    version_after_confirmation = guest.session_version
    signed_out_at = tracked_guest_session.signed_out_at
    visit user_confirmation_path(confirmation_token: token)

    aggregate_failures do
      expect(page).to have_no_content(I18n.t("flash.users.guest_registration.completed"))
      expect(guest.reload).not_to be_guest
      expect(guest.session_version).to eq(version_after_confirmation)
      expect(tracked_guest_session.reload.signed_out_at).to eq(signed_out_at)
      expect(guest.user_sessions.count).to eq(1)
    end

    submit_password_login(email: registered_email, password: registered_password)

    expect(page).to have_current_path(receipts_path, ignore_query: true)
    registered_session = guest.user_sessions.where.not(id: tracked_guest_session.id).order(:id).last

    aggregate_failures do
      expect(registered_session).to be_present
      expect(registered_session.session_version).to eq(guest.session_version)
      expect(registered_session.sign_in_method).to eq("password")
      expect(User.guest_cleanup_candidates(1.year.from_now)).not_to include(guest)
    end

    travel 8.days do
      result = GuestUserCleanupJob.perform_now

      aggregate_failures do
        expect(result).to eq(deleted_count: 0, failed_count: 0)
        expect(User.where(id: guest.id)).to exist
      end
    end

    expect_browser_console_clean
  end

  it "期限切れtokenを同じbrowserで拒否し、guest状態とsessionを維持する" do
    issued_at = Time.zone.parse("2026-05-23 10:00:00")
    guest = nil
    token = nil

    travel_to(issued_at) do
      guest, token = start_guest_registration_via_browser(
        email: "browser-expired-guest-confirmation@example.com"
      )
    end

    original_email = guest.email
    original_session_version = guest.session_version
    tracked_session = guest.user_sessions.order(:id).last

    travel_to(issued_at + 3.days + 1.minute) do
      visit user_confirmation_path(confirmation_token: token)
    end

    aggregate_failures do
      expect(page).to have_content(I18n.t("auth.confirmations.new.title"))
      expect(page).to have_content("期限")
      expect(guest.reload).to be_guest
      expect(guest.email).to eq(original_email)
      expect(guest.unconfirmed_email).to eq("browser-expired-guest-confirmation@example.com")
      expect(guest.session_version).to eq(original_session_version)
      expect(tracked_session.reload.signed_out_at).to be_nil
    end

    visit settings_security_path
    expect(page).to have_css("#guest-registration")
    expect_browser_console_clean
  end

  it "confirmation途中のDB失敗をrollbackし、同じbrowserから再試行できる" do
    guest, token = start_guest_registration_via_browser(
      email: "browser-atomic-guest-confirmation@example.com"
    )
    guest.reload
    original_email = guest.email
    original_session_version = guest.session_version
    original_confirmation_token = guest.confirmation_token
    tracked_session = guest.user_sessions.order(:id).last

    allow_any_instance_of(User).to receive(:complete_guest_registration!)
      .and_raise(ActiveRecord::StatementInvalid, "local fault injection")

    visit user_confirmation_path(confirmation_token: token)

    server_error = page.server.error
    expected_console_entries = browser_console_entries.reject do |entry|
      blocked_external_font_entry?(entry)
    end

    aggregate_failures do
      expect(server_error).to be_a(ActiveRecord::StatementInvalid)
      expect(server_error.message).to eq("local fault injection")
      expect(expected_console_entries).to contain_exactly(
        an_object_having_attributes(level: "SEVERE", message: include("500 (Internal Server Error)"))
      )
    end
    page.server.reset_error!

    aggregate_failures do
      expect(guest.reload).to be_guest
      expect(guest.email).to eq(original_email)
      expect(guest.unconfirmed_email).to eq("browser-atomic-guest-confirmation@example.com")
      expect(guest.confirmation_token).to eq(original_confirmation_token)
      expect(guest.session_version).to eq(original_session_version)
      expect(tracked_session.reload.signed_out_at).to be_nil
    end

    allow_any_instance_of(User).to receive(:complete_guest_registration!).and_call_original
    visit user_confirmation_path(confirmation_token: token)

    aggregate_failures do
      expect(page).to have_current_path(new_user_session_path, ignore_query: true)
      expect(page).to have_content(I18n.t("flash.users.guest_registration.completed"))
      expect(guest.reload).not_to be_guest
      expect(tracked_session.reload.signed_out_at).to be_present
    end

    expect_browser_console_clean
  end
end
