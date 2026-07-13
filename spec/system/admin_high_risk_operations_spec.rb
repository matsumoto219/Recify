require "rails_helper"
require_relative "../support/system_test_helpers"
require "webauthn/fake_client"

RSpec.describe "管理画面の高リスク操作", type: :system do
  include ActiveSupport::Testing::TimeHelpers

  RAW_ARTIFACT_BODY = JSON.generate(
    "status" => "succeeded",
    "analyzeResult" => { "content" => "LOCAL SYSTEM SPEC ARTIFACT" }
  ).freeze

  around do |example|
    original_rack_attack_store = Rack::Attack.cache.store
    original_rate_limit_store = ApplicationController::RateLimitStore.instance_variable_get(:@store)
    rate_limit_store = ActiveSupport::Cache::MemoryStore.new
    rack_attack_store = ActiveSupport::Cache::MemoryStore.new

    ApplicationController.rate_limit_cache_store = rate_limit_store
    Rack::Attack.cache.store = rack_attack_store
    Rack::Attack.reset!
    example.run
  ensure
    travel_back
    rate_limit_store&.clear
    ApplicationController.rate_limit_cache_store = original_rate_limit_store
    Rack::Attack.reset!
    Rack::Attack.cache.store = original_rack_attack_store
  end

  def with_mobile_viewport
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true
    )
    yield
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  # 実機のWebAuthn認証ではないが、FakeClientが実challengeへ署名したassertionをサーバー側で検証する。
  def webauthn_fake_client
    @webauthn_fake_client ||= WebAuthn::FakeClient.new("http://localhost:3000")
  end

  def create_fake_client_passkey(user)
    options = Passkeys.registration_options(user: user)
    credential = webauthn_fake_client.create(
      challenge: options.challenge,
      rp_id: "localhost",
      user_verified: true
    )

    Passkeys.verify_registration(user: user, credential: credential, challenge: options.challenge)
  end

  def prepared_browser_request_options
    wait_for_stimulus_controller("passkey-session")

    result = page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[arguments.length - 1]
      const controller = window.Stimulus.controllers.find(
        (candidate) => candidate.identifier === "passkey-session"
      )
      const encode = (buffer) => {
        const bytes = new Uint8Array(buffer)
        let binary = ""
        bytes.forEach((byte) => { binary += String.fromCharCode(byte) })
        return window.btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "")
      }

      Promise.resolve(controller.prepareRequestOptions())
        .then((publicKey) => done({
          challenge: encode(publicKey.challenge),
          rpId: publicKey.rpId,
          allowCredentialIds: (publicKey.allowCredentials || []).map((entry) => encode(entry.id))
        }))
        .catch((error) => done({ error: error?.name || "PasskeyOptionsError" }))
    JAVASCRIPT

    expect(result.fetch("error", nil)).to be_nil
    result
  end

  def install_fake_client_browser_credential(credential, expected_challenge:)
    page.execute_script(<<~JAVASCRIPT, credential, expected_challenge)
      const assertion = arguments[0]
      const expectedChallenge = arguments[1]
      const decode = (value) => {
        const base64 = value.replace(/-/g, "+").replace(/_/g, "/")
        const padded = base64.padEnd(base64.length + ((4 - base64.length % 4) % 4), "=")
        const binary = window.atob(padded)
        return Uint8Array.from(binary, (character) => character.charCodeAt(0)).buffer
      }
      const encode = (buffer) => {
        const bytes = new Uint8Array(buffer)
        let binary = ""
        bytes.forEach((byte) => { binary += String.fromCharCode(byte) })
        return window.btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "")
      }

      Object.defineProperty(navigator, "credentials", {
        configurable: true,
        value: {
          get: async ({ publicKey }) => {
            if (encode(publicKey.challenge) !== expectedChallenge) {
              throw new DOMException("Passkey challenge changed", "SecurityError")
            }

            const allowedIds = (publicKey.allowCredentials || []).map((entry) => encode(entry.id))
            if (!allowedIds.includes(assertion.id)) {
              throw new DOMException("Passkey credential is not allowed", "SecurityError")
            }

            return {
              type: assertion.type,
              id: assertion.id,
              rawId: decode(assertion.rawId),
              authenticatorAttachment: assertion.authenticatorAttachment,
              getClientExtensionResults: () => assertion.clientExtensionResults || {},
              response: {
                authenticatorData: decode(assertion.response.authenticatorData),
                clientDataJSON: decode(assertion.response.clientDataJSON),
                signature: decode(assertion.response.signature),
                userHandle: assertion.response.userHandle ? decode(assertion.response.userHandle) : null
              }
            }
          }
        }
      })
    JAVASCRIPT
  end

  def complete_fake_client_browser_reauthentication(passkey:, expected_return_path:)
    request_options = prepared_browser_request_options
    expect(request_options.fetch("allowCredentialIds")).to include(passkey.credential_id)
    previous_sign_count = passkey.sign_count

    credential = webauthn_fake_client.get(
      challenge: request_options.fetch("challenge"),
      rp_id: request_options.fetch("rpId"),
      user_verified: true,
      allow_credentials: [ passkey.credential_id ]
    )
    install_fake_client_browser_credential(
      credential,
      expected_challenge: request_options.fetch("challenge")
    )
    click_button I18n.t("admin.passkey_reauthentications.new.submit")

    expect(page).to have_current_path(expected_return_path, ignore_query: true)
    aggregate_failures do
      expect(passkey.reload.sign_count).to be > previous_sign_count
      expect(passkey.last_used_at).to be_present
    end
  end

  def reauthenticate_through_browser(passkey:, return_to:)
    visit new_admin_passkey_reauthentication_path(return_to: return_to)
    complete_fake_client_browser_reauthentication(passkey: passkey, expected_return_path: return_to)
  end

  def expect_exact_mobile_viewport_without_overflow
    aggregate_failures do
      expect(page.evaluate_script("window.innerWidth")).to eq(390)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    end
  end

  def expect_only_expected_browser_failure(pattern)
    severe_entries = browser_console_entries.select do |entry|
      entry.level == "SEVERE" && !blocked_external_font_entry?(entry)
    end
    expected_entries, unexpected_entries = severe_entries.partition { |entry| entry.message.match?(pattern) }

    aggregate_failures do
      expect(expected_entries.size).to eq(1)
      expect(unexpected_entries).to be_empty
    end
  end

  def retry_option_card(retry_type)
    find("div.font-semibold", text: retry_type, exact_text: true).find(:xpath, "..")
  end

  def fetch_same_origin(url)
    page.evaluate_async_script(<<~JAVASCRIPT, url)
      const url = arguments[0]
      const done = arguments[arguments.length - 1]

      fetch(url, { credentials: "same-origin" })
        .then(async (response) => {
          done({
            status: response.status,
            body: await response.text(),
            cacheControl: response.headers.get("cache-control"),
            contentDisposition: response.headers.get("content-disposition"),
            contentTypeOptions: response.headers.get("x-content-type-options")
          })
        })
        .catch((error) => done({ error: error.message }))
    JAVASCRIPT
  end

  it "390px darkで本人確認後にhigh-risk設定を更新し、依存違反の入力を保持してresetする", :mobile do
    with_mobile_viewport do
      admin = create_system_test_user(admin: true, theme_preference: "dark")
      sign_in_through_browser(admin)
      passkey = create_fake_client_passkey(admin)

      setting_path = admin_system_setting_path("security.user_reauth_window_minutes")
      visit setting_path

      aggregate_failures do
        expect(page).to have_css("html[data-theme='dark']")
        expect(page).to have_link(I18n.t("admin.system_settings.show.update.reauthentication_link"))
        expect(page).to have_no_field("value")
      end

      click_link I18n.t("admin.system_settings.show.update.reauthentication_link")
      complete_fake_client_browser_reauthentication(passkey: passkey, expected_return_path: setting_path)

      aggregate_failures do
        expect(page).to have_field("value", with: "5")
        expect(page).to have_field("reason", with: "", exact: true)
        expect(page).to have_unchecked_field("confirm")
        expect(find("textarea[name='reason']")[:required]).to eq("true")
        expect(find("input[name='confirm']")[:required]).to eq("true")
      end

      fill_in "value", with: "10"
      fill_in "reason", with: "system spec security window update"
      check "confirm"
      click_button I18n.t("admin.system_settings.show.update.submit")

      expect(page).to have_current_path(setting_path, ignore_query: true)
      expect(page).to have_content(I18n.t("admin.system_settings.messages.updated"))

      updated_setting = SystemSetting.find_by!(key: "security.user_reauth_window_minutes")
      update_audit = AuditLog.find_by!(
        action: "system_settings.update",
        target_uid: "security.user_reauth_window_minutes"
      )

      aggregate_failures do
        expect(updated_setting.value).to eq(SystemSettings.stored_value(10))
        expect(update_audit).to have_attributes(outcome: "succeeded", actor_user: admin)
        expect(update_audit.before_state).to include("value" => 5, "source" => "default")
        expect(update_audit.after_state).to include("value" => 10, "source" => "db")
      end

      dependency_path = admin_system_setting_path("external_services.ai.read_timeout_seconds")
      visit dependency_path
      fill_in "value", with: "300"
      fill_in "reason", with: "system spec dependency failure"
      check "confirm"
      click_button I18n.t("admin.system_settings.show.update.submit")

      expect(page).to have_current_path(dependency_path, ignore_query: true)
      expect(page).to have_content("最大処理時間を950秒以上")

      failed_audit = AuditLog.find_by!(
        action: "system_settings.update",
        target_uid: "external_services.ai.read_timeout_seconds"
      )

      aggregate_failures do
        expect(page).to have_field("value", with: "300")
        expect(page).to have_field("reason", with: "system spec dependency failure")
        expect(page).to have_checked_field("confirm")
        expect(SystemSetting.find_by(key: "external_services.ai.read_timeout_seconds")).to be_nil
        expect(failed_audit).to have_attributes(
          outcome: "failed",
          error_code: "external_service_ai_elapsed_budget"
        )
      end

      visit setting_path
      fill_in "reason", with: "system spec restore default"
      check "confirm"
      click_button I18n.t("admin.system_settings.show.update.reset")

      expect(page).to have_current_path(setting_path, ignore_query: true)
      expect(page).to have_content(I18n.t("admin.system_settings.messages.reset"))

      reset_audit = AuditLog.find_by!(
        action: "system_settings.reset",
        target_uid: "security.user_reauth_window_minutes"
      )

      aggregate_failures do
        expect(SystemSetting.find_by(key: "security.user_reauth_window_minutes")).to be_nil
        expect(reset_audit).to have_attributes(outcome: "succeeded", actor_user: admin)
        expect(reset_audit.before_state).to include("value" => 10, "source" => "db")
        expect(reset_audit.after_state).to include("value" => 5, "source" => "default")
        expect(page).to have_css("html[data-theme='dark']")
      end

      expect_exact_mobile_viewport_without_overflow
      expect_only_expected_browser_failure(
        %r{/admin/system_settings/external_services\.ai\.read_timeout_seconds.+422}
      )
    end
  end

  it "390px lightでraw artifactとretry可否をfreshnessで保護し、期限切れ後に再び隠す", :mobile do
    with_mobile_viewport do
      admin = create_system_test_user(admin: true, theme_preference: "light")
      sign_in_through_browser(admin)
      passkey = create_fake_client_passkey(admin)

      receipt = create(:receipt, :completed, user: admin)
      run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: {
          "success" => true,
          "lines" => [ "合計 1000" ],
          "candidates" => { "total_amount" => 1000 }
        },
        ai_normalized_result_snapshot: {
          "success" => true,
          "receipt_attributes" => { "total_amount" => 1000 },
          "receipt_items_attributes" => []
        },
        metadata: {
          "finalize_decision" => {
            "schema_version" => "receipt_analysis_run_finalize_decision_v1",
            "strategy" => "ai_success",
            "recorded_at" => Time.current.iso8601
          }
        }
      )
      filename = "ocr_response_#{run.run_key}_attempt01.json"
      run.ocr_response_artifact.attach(
        io: StringIO.new(RAW_ARTIFACT_BODY),
        filename: filename,
        content_type: "application/json"
      )
      run_path = admin_receipt_analysis_run_path(run.run_key)
      artifact_path = ocr_response_artifact_admin_receipt_analysis_run_path(run.run_key, variant: :raw)

      visit run_path

      aggregate_failures do
        expect(page).to have_css("html[data-theme='light']")
        expect(page).to have_link(I18n.t("admin.receipt_analysis_runs.show.ocr_response_artifact.reauthentication_link"))
        expect(page).to have_no_link(I18n.t("admin.receipt_analysis_runs.show.ocr_response_artifact.download_raw"))
        expect(page).to have_no_css("input[name='retry_kind']", visible: :all)
      end

      visit artifact_path
      expect(page).to have_current_path(new_admin_passkey_reauthentication_path, ignore_query: true)
      complete_fake_client_browser_reauthentication(passkey: passkey, expected_return_path: run_path)

      ocr_retry_card = retry_option_card("ocr_retry")
      ai_retry_card = retry_option_card("ai_retry")
      finalize_retry_card = retry_option_card("finalize_retry")

      aggregate_failures do
        expect(page).to have_link(I18n.t("admin.receipt_analysis_runs.show.ocr_response_artifact.download_raw"))
        expect(ocr_retry_card).to have_content("disabled: image_missing")
        expect(ocr_retry_card).to have_no_css("input[name='retry_kind'][value='ocr_retry']", visible: :all)
        expect(ai_retry_card).to have_content("disabled: ai_unavailable")
        expect(ai_retry_card).to have_no_css("input[name='retry_kind'][value='ai_retry']", visible: :all)
        expect(finalize_retry_card).to have_content(I18n.t("admin.receipt_analysis_runs.show.retry.available"))
        expect(finalize_retry_card).to have_css(
          "input[name='retry_kind'][value='finalize_retry']",
          visible: :all
        )
      end

      artifact_response = fetch_same_origin(artifact_path)
      download_audit = AuditLog.find_by!(
        action: "receipt_analysis_runs.ocr_response_artifact.download",
        target_uid: run.run_key
      )

      aggregate_failures do
        expect(artifact_response).to include(
          "status" => 200,
          "body" => RAW_ARTIFACT_BODY,
          "contentTypeOptions" => "nosniff"
        )
        expect(artifact_response.fetch("cacheControl")).to include("no-store")
        expect(artifact_response.fetch("contentDisposition")).to include("attachment", filename)
        expect(download_audit).to have_attributes(outcome: "succeeded", actor_user: admin)
        expect(download_audit.metadata.to_json).not_to include(
          "LOCAL SYSTEM SPEC ARTIFACT",
          run.ocr_response_artifact.blob.key,
          "signed_id"
        )
      end

      travel 6.minutes do
        visit run_path

        aggregate_failures do
          expect(page).to have_link(I18n.t("admin.receipt_analysis_runs.show.ocr_response_artifact.reauthentication_link"))
          expect(page).to have_no_link(I18n.t("admin.receipt_analysis_runs.show.ocr_response_artifact.download_raw"))
          expect(page).to have_no_css("input[name='retry_kind']", visible: :all)
        end
      end

      expect_exact_mobile_viewport_without_overflow
      expect_browser_console_clean
    end
  end

  it "FakeClient再認証のfreshnessを別adminのbrowser sessionへ継承しない" do
    first_admin = create_system_test_user(admin: true)
    second_admin = create_system_test_user(admin: true)
    setting_path = admin_system_setting_path("security.user_reauth_window_minutes")

    Capybara.using_session(:first_admin) do
      sign_in_through_browser(first_admin)
      first_passkey = create_fake_client_passkey(first_admin)
      reauthenticate_through_browser(passkey: first_passkey, return_to: setting_path)
      expect(page).to have_field("value", with: "5")
      expect_browser_console_clean
    end

    Capybara.using_session(:second_admin) do
      sign_in_through_browser(second_admin)
      create_fake_client_passkey(second_admin)
      visit setting_path

      aggregate_failures do
        expect(page).to have_link(I18n.t("admin.system_settings.show.update.reauthentication_link"))
        expect(page).to have_no_field("value")
      end
      expect_browser_console_clean
    end

    Capybara.using_session(:first_admin) do
      visit setting_path
      expect(page).to have_field("value", with: "5")
      expect_browser_console_clean
    end
  end
end
