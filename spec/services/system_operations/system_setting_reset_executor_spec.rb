# frozen_string_literal: true

require "rails_helper"

RSpec.describe SystemOperations::SystemSettingResetExecutor do
  include ActiveSupport::Testing::TimeHelpers

  let(:actor) { create(:user, :admin) }
  let(:request) do
    instance_double(
      ActionDispatch::Request,
      request_id: "reset-request-id",
      remote_ip: "127.0.0.1",
      user_agent: "System Setting Reset Spec"
    )
  end
  let(:reauthentication) do
    {
      method: "passkey",
      reauthenticated_at: Time.current,
      user_id: actor.id,
      session_version: actor.session_version,
      expires_at: Time.current + Admin.passkey_reauth_window_duration,
      credential_id: "credential-secret",
      challenge: "challenge-secret"
    }
  end

  around do |example|
    travel_to(Time.zone.parse("2026-07-11 12:00:00")) { example.run }
  end

  it "DB overrideを削除して既定値へ戻し、before/after監査を残す" do
    setting = create(
      :system_setting,
      key: "feature.receipt_logo_display_enabled",
      value: SystemSettings.stored_value(true),
      updated_by_user: actor
    )

    result = described_class.call(
      key: setting.key,
      actor: actor,
      reason: "return to application default",
      request: request,
      reauthentication: reauthentication
    )

    audit_log = AuditLog.last

    aggregate_failures do
      expect(result).to be_success
      expect(SystemSetting.find_by(key: setting.key)).to be_nil
      expect(SystemSettings.fetch(setting.key)).to have_attributes(current_value: false, source: "default")
      expect(audit_log).to have_attributes(
        action: "system_settings.reset",
        outcome: "succeeded",
        target_uid: setting.key,
        reason: "return to application default"
      )
      expect(audit_log.before_state).to eq("value" => true, "source" => "db")
      expect(audit_log.after_state).to eq("value" => false, "source" => "default")
      expect(audit_log.attributes.to_json).not_to include("credential-secret", "challenge-secret")
    end
  end

  it "high-risk設定のresetに確認を必須とする" do
    setting = create(
      :system_setting,
      key: "external_services.ai.max_elapsed_seconds",
      value: SystemSettings.stored_value(1200),
      updated_by_user: actor
    )

    result = described_class.call(
      key: setting.key,
      actor: actor,
      reason: "reset runtime budget",
      request: request,
      reauthentication: reauthentication,
      confirmation: "0"
    )

    aggregate_failures do
      expect(result).to be_failure
      expect(result.error_code).to eq("confirmation_required")
      expect(setting.reload.value).to eq("value" => 1200)
      expect(AuditLog.last).to have_attributes(outcome: "failed", error_code: "confirmation_required")
    end
  end

  it "既定値で依存関係が壊れるresetを同じdependency lock内で拒否する" do
    create(
      :system_setting,
      key: "external_services.ai.max_elapsed_seconds",
      value: SystemSettings.stored_value(1200),
      updated_by_user: actor
    )
    create(
      :system_setting,
      key: "external_services.ai.read_timeout_seconds",
      value: SystemSettings.stored_value(300),
      updated_by_user: actor
    )
    allow(SystemOperations::SystemSettingDependencyLock).to receive(:call).and_call_original

    result = described_class.call(
      key: "external_services.ai.max_elapsed_seconds",
      actor: actor,
      reason: "unsafe reset check",
      request: request,
      reauthentication: reauthentication,
      confirmation: "1"
    )

    aggregate_failures do
      expect(result).to be_failure
      expect(result.error_code).to eq("external_service_ai_elapsed_budget")
      expect(SystemSetting.find_by!(key: "external_services.ai.max_elapsed_seconds").value).to eq("value" => 1200)
      expect(SystemOperations::SystemSettingDependencyLock).to have_received(:call)
        .with(groups: [ "external_service_ai_runtime" ])
    end
  end

  it "activeなreceipt item overrideを壊すsnapshot既定値へのresetを拒否する" do
    create(
      :system_setting,
      key: "limits.snapshot_ocr_items_max",
      value: SystemSettings.stored_value(1500),
      updated_by_user: actor
    )
    create(
      :system_setting,
      key: "limits.snapshot_ai_normalized_items_max",
      value: SystemSettings.stored_value(1500),
      updated_by_user: actor
    )
    create(
      :user_limit_override,
      user: create(:user),
      key: "receipt_items_per_receipt",
      value: { "value" => 1200 }
    )

    result = described_class.call(
      key: "limits.snapshot_ocr_items_max",
      actor: actor,
      reason: "unsafe snapshot reset with active override",
      request: request,
      reauthentication: reauthentication,
      confirmation: "1"
    )

    aggregate_failures do
      expect(result).to be_failure
      expect(result.error_code).to eq("receipt_items_snapshot_limit")
      expect(SystemSettings.limit_for("limits.snapshot_ocr_items_max")).to eq(1500)
      expect(AuditLog.last).to have_attributes(outcome: "failed", error_code: "receipt_items_snapshot_limit")
    end
  end

  it "依存値を安全な順番でresetすれば詰まずに全て既定値へ戻せる" do
    create(
      :system_setting,
      key: "external_services.ai.max_elapsed_seconds",
      value: SystemSettings.stored_value(1200),
      updated_by_user: actor
    )
    create(
      :system_setting,
      key: "external_services.ai.read_timeout_seconds",
      value: SystemSettings.stored_value(300),
      updated_by_user: actor
    )

    read_result = described_class.call(
      key: "external_services.ai.read_timeout_seconds",
      actor: actor,
      reason: "restore dependent timeout first",
      request: request,
      reauthentication: reauthentication,
      confirmation: "1"
    )
    elapsed_result = described_class.call(
      key: "external_services.ai.max_elapsed_seconds",
      actor: actor,
      reason: "restore elapsed budget second",
      request: request,
      reauthentication: reauthentication,
      confirmation: "1"
    )

    aggregate_failures do
      expect(read_result).to be_success
      expect(elapsed_result).to be_success
      expect(SystemSettings.fetch("external_services.ai.read_timeout_seconds")).to have_attributes(
        current_value: 120,
        source: "default"
      )
      expect(SystemSettings.fetch("external_services.ai.max_elapsed_seconds")).to have_attributes(
        current_value: 600,
        source: "default"
      )
    end
  end

  it "DB overrideがないresetを成功扱いにしない" do
    result = described_class.call(
      key: "feature.receipt_logo_display_enabled",
      actor: actor,
      reason: "duplicate reset",
      request: request,
      reauthentication: reauthentication
    )

    aggregate_failures do
      expect(result).to be_failure
      expect(result.error_code).to eq("setting_already_default")
      expect(AuditLog.last).to have_attributes(outcome: "failed", error_code: "setting_already_default")
    end
  end
end
