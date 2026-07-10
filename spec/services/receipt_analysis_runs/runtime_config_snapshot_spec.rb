require "rails_helper"

RSpec.describe ReceiptAnalysisRuns::RuntimeConfigSnapshot do
  let(:receipt) { create(:receipt) }
  let(:run) { create(:receipt_analysis_run, receipt:) }

  it "初回取得時の設定をrun metadataへ保存して同じrunでは固定する" do
    first_snapshot = ReceiptAnalysisRuns.external_service_runtime_config(run)
    create(
      :system_setting,
      key: "external_services.ai.max_elapsed_seconds",
      value: SystemSettings.stored_value(1200)
    )
    create(
      :system_setting,
      key: "external_services.ai.read_timeout_seconds",
      value: SystemSettings.stored_value(300)
    )

    second_snapshot = ReceiptAnalysisRuns.external_service_runtime_config(run.reload)

    aggregate_failures do
      expect(first_snapshot.ai.read_timeout_seconds).to eq(120)
      expect(second_snapshot).to eq(first_snapshot)
      expect(run.metadata.fetch("external_service_runtime_config"))
        .to eq(first_snapshot.serializable_hash)
    end
  end

  it "新しいrunでは最新の設定を取得する" do
    first_snapshot = ReceiptAnalysisRuns.external_service_runtime_config(run)
    create(
      :system_setting,
      key: "external_services.ai.max_elapsed_seconds",
      value: SystemSettings.stored_value(1200)
    )
    create(
      :system_setting,
      key: "external_services.ai.read_timeout_seconds",
      value: SystemSettings.stored_value(300)
    )
    next_run = create(:receipt_analysis_run, receipt: create(:receipt))

    second_snapshot = ReceiptAnalysisRuns.external_service_runtime_config(next_run)

    aggregate_failures do
      expect(first_snapshot.ai.read_timeout_seconds).to eq(120)
      expect(second_snapshot.ai.read_timeout_seconds).to eq(300)
    end
  end

  it "SystemSettings取得失敗時は安全な共通errorを返しmetadataを保存しない" do
    allow(SystemSettings).to receive(:values_for).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect { ReceiptAnalysisRuns.external_service_runtime_config(run) }
      .to raise_error(ExternalServices::RuntimeConfigUnavailableError)
    expect(run.reload.metadata).not_to have_key("external_service_runtime_config")
  end
end
