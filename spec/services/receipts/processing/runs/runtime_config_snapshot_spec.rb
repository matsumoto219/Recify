require "rails_helper"

RSpec.describe Receipts::Processing::Runs::RuntimeConfigSnapshot do
  let(:receipt) { create(:receipt) }
  let(:run) { create(:receipt_analysis_run, receipt:) }

  it "Starterでrunを作成した時点の設定を固定する" do
    started_run = Receipts::Processing::Runs.start(receipt:, source: "upload").run
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

    snapshot = Receipts::Processing::Runs.external_service_runtime_config(started_run.reload)

    aggregate_failures do
      expect(snapshot.ai.read_timeout_seconds).to eq(120)
      expect(started_run.metadata.fetch("external_service_runtime_config"))
        .to eq(snapshot.serializable_hash)
      expect(started_run.metadata.fetch("external_service_runtime_config_origin"))
        .to eq("run_creation")
    end
  end

  it "新しいrunでは最新の設定を取得する" do
    first_run = Receipts::Processing::Runs.start(receipt:, source: "upload").run
    first_snapshot = Receipts::Processing::Runs.external_service_runtime_config(first_run)
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
    next_run = Receipts::Processing::Runs.start(receipt: create(:receipt), source: "upload").run

    second_snapshot = Receipts::Processing::Runs.external_service_runtime_config(next_run)

    aggregate_failures do
      expect(first_snapshot.ai.read_timeout_seconds).to eq(120)
      expect(second_snapshot.ai.read_timeout_seconds).to eq(300)
    end
  end

  it "legacy runは初回取得時の設定を互換保存し起点を明示する" do
    snapshot = Receipts::Processing::Runs.external_service_runtime_config(run)

    aggregate_failures do
      expect(run.reload.metadata.fetch("external_service_runtime_config"))
        .to eq(snapshot.serializable_hash)
      expect(run.metadata.fetch("external_service_runtime_config_origin"))
        .to eq("legacy_execution_capture")
    end
  end

  it "新方式runでsnapshotが欠落した場合は再取得せずfail-closedにする" do
    run.update!(metadata: { "external_service_runtime_config_origin" => "run_creation" })
    allow(ExternalServices).to receive(:runtime_config_snapshot)

    expect { Receipts::Processing::Runs.external_service_runtime_config(run) }
      .to raise_error(ExternalServices::RuntimeConfigUnavailableError)
    expect(ExternalServices).not_to have_received(:runtime_config_snapshot)
  end

  it "SystemSettings取得失敗時はrunを作成せずprocessing receiptをfailedへ補償する" do
    processing_receipt = create(:receipt, :processing, :with_image)
    allow(SystemSettings).to receive(:values_for).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect { Receipts::Processing::Runs.start(receipt: processing_receipt, source: "upload") }
      .to raise_error(ExternalServices::RuntimeConfigUnavailableError)

    aggregate_failures do
      expect(processing_receipt.receipt_analysis_runs).to be_empty
      expect(processing_receipt.reload).to have_attributes(
        status: "failed",
        processing_error_code: "runtime_config_unavailable",
        processing_error_message: I18n.t("receipts.processing_errors.unexpected_failure")
      )
    end
  end
end
