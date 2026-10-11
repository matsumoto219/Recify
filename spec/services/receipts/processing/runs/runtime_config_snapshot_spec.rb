require "rails_helper"

RSpec.describe Receipts::Processing::Runs::RuntimeConfigSnapshot do
  let(:receipt) { create(:receipt) }
  let(:run) { create(:receipt_analysis_run, receipt:) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OPENAI_AI_MODEL").and_return("gpt-6-luna")
  end

  it "Starterでrunを作成した時点の設定を固定する" do
    started_run = Receipts::Processing::Runs.start(receipt:, source: "upload").run
    create(
      :system_setting,
      key: "external_services.ai.max_elapsed_seconds",
      value: SystemSettings.stored_value(1800)
    )
    create(
      :system_setting,
      key: "external_services.ai.read_timeout_seconds",
      value: SystemSettings.stored_value(450)
    )
    create(:system_setting, key: "external_services.ai.reasoning_effort", value: SystemSettings.stored_value("medium"))
    create(:system_setting, key: "external_services.ai.name_completion_reasoning_effort", value: SystemSettings.stored_value("xhigh"))
    allow(ENV).to receive(:[]).with("OPENAI_AI_MODEL").and_return("future-model")

    snapshot = Receipts::Processing::Runs.external_service_runtime_config(started_run.reload)

    aggregate_failures do
      expect(snapshot.ai).to have_attributes(read_timeout_seconds: 300, max_elapsed_seconds: 1200, max_retries: 2)
      expect(snapshot.ai).to have_attributes(model: "gpt-6-luna", reasoning_effort: "low", name_completion_reasoning_effort: "high")
      expect(started_run.metadata.fetch("external_service_runtime_config"))
        .to eq(snapshot.serializable_hash)
      expect(started_run.metadata.fetch("external_service_runtime_config_origin"))
        .to eq("run_creation")
      expect(started_run.metadata.fetch("external_service_ai_config_origin")).to eq("run_creation")
    end
  end

  it "旧timeoutで作ったrunのretryは固定値を維持し新しいrunだけ現在の既定値を取得する" do
    read_timeout = create(:system_setting, key: "external_services.ai.read_timeout_seconds", value: SystemSettings.stored_value(120))
    elapsed = create(:system_setting, key: "external_services.ai.max_elapsed_seconds", value: SystemSettings.stored_value(600))
    first_run = Receipts::Processing::Runs.start(receipt:, source: "upload").run
    first_snapshot = Receipts::Processing::Runs.external_service_runtime_config(first_run)
    elapsed.destroy!
    read_timeout.destroy!
    next_run = Receipts::Processing::Runs.start(receipt: create(:receipt), source: "upload").run

    second_snapshot = Receipts::Processing::Runs.external_service_runtime_config(next_run)

    aggregate_failures do
      expect(first_snapshot.ai).to have_attributes(read_timeout_seconds: 120, max_elapsed_seconds: 600, max_retries: 2)
      expect(Receipts::Processing::Runs.external_service_runtime_config(first_run.reload)).to eq(first_snapshot)
      expect(second_snapshot.ai).to have_attributes(read_timeout_seconds: 300, max_elapsed_seconds: 1200, max_retries: 2)
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

  it "旧timing snapshotは15値と起点を変えず不足するAI設定だけ一度固定する" do
    stored = ExternalServices.runtime_config_snapshot.serializable_hash
    stored.fetch("ai").merge!("read_timeout_seconds" => 120, "max_elapsed_seconds" => 600)
    stored.delete("ai_execution_config_version")
    stored.fetch("ai").except!("model", "reasoning_effort", "name_completion_reasoning_effort")
    run.update!(metadata: {
      "external_service_runtime_config" => stored,
      "external_service_runtime_config_origin" => "run_creation"
    })
    create(:system_setting, key: "external_services.ai.read_timeout_seconds", value: SystemSettings.stored_value(150))
    create(:system_setting, key: "external_services.ai.reasoning_effort", value: SystemSettings.stored_value("medium"))
    allow(SystemSettings).to receive(:values_for).and_call_original
    first = described_class.fetch_or_record(run)
    allow(ENV).to receive(:[]).with("OPENAI_AI_MODEL").and_return("another-model")

    second = described_class.fetch_or_record(run.reload)

    aggregate_failures do
      expect(first.ai).to have_attributes(read_timeout_seconds: 120, model: "gpt-6-luna", reasoning_effort: "medium", name_completion_reasoning_effort: "high")
      expect(second).to eq(first)
      expect(first.serializable_hash.fetch("ai").except("model", "reasoning_effort", "name_completion_reasoning_effort")).to eq(stored.fetch("ai"))
      expect(first.serializable_hash.fetch("ocr")).to eq(stored.fetch("ocr"))
      expect(run.metadata.fetch("external_service_runtime_config_origin")).to eq("run_creation")
      expect(run.metadata.fetch("external_service_ai_config_origin")).to eq("legacy_execution_capture")
      expect(SystemSettings).to have_received(:values_for).with(%w[external_services.ai.reasoning_effort external_services.ai.name_completion_reasoning_effort]).once
    end
  end

  it "新方式のAI設定が消えた場合は旧snapshotとして補完しない" do
    run = Receipts::Processing::Runs.start(receipt:, source: "upload").run
    metadata = run.metadata.deep_dup
    metadata.fetch("external_service_runtime_config").delete("ai_execution_config_version")
    metadata.dig("external_service_runtime_config", "ai").except!("model", "reasoning_effort", "name_completion_reasoning_effort")
    run.update!(metadata: metadata)
    allow(ExternalServices).to receive(:runtime_config_snapshot)

    expect { described_class.fetch_or_record(run) }.to raise_error(ExternalServices::RuntimeConfigUnavailableError)
    expect(ExternalServices).not_to have_received(:runtime_config_snapshot)
  end

  it "旧snapshotのAI設定取得に失敗してもtiming値と起点を変更しない" do
    stored = ExternalServices.runtime_config_snapshot.serializable_hash
    stored.delete("ai_execution_config_version")
    stored.fetch("ai").except!("model", "reasoning_effort", "name_completion_reasoning_effort")
    metadata = {
      "external_service_runtime_config" => stored,
      "external_service_runtime_config_origin" => "legacy_execution_capture"
    }
    run.update!(metadata: metadata)
    allow(SystemSettings).to receive(:values_for).and_call_original
    allow(SystemSettings).to receive(:values_for)
      .with(%w[external_services.ai.reasoning_effort external_services.ai.name_completion_reasoning_effort])
      .and_raise(ActiveRecord::ConnectionNotEstablished)

    expect { described_class.fetch_or_record(run) }.to raise_error(ExternalServices::RuntimeConfigUnavailableError)
    expect(run.reload.metadata).to eq(metadata)
  end

  it "旧snapshotの補完保存に失敗してもtiming値と起点を変更しない" do
    stored = ExternalServices.runtime_config_snapshot.serializable_hash
    stored.delete("ai_execution_config_version")
    stored.fetch("ai").except!("model", "reasoning_effort", "name_completion_reasoning_effort")
    metadata = {
      "external_service_runtime_config" => stored,
      "external_service_runtime_config_origin" => "run_creation"
    }
    run.update!(metadata: metadata)
    allow(run).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)

    expect { described_class.fetch_or_record(run) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(run.reload.metadata).to eq(metadata)
  end

  it "新AI設定が部分欠損している場合は再取得せずfail-closedにする" do
    stored = ExternalServices.runtime_config_snapshot.serializable_hash
    stored.fetch("ai").delete("model")
    run.update!(metadata: { "external_service_runtime_config" => stored })
    allow(ExternalServices).to receive(:runtime_config_snapshot)

    expect { described_class.fetch_or_record(run) }.to raise_error(ExternalServices::RuntimeConfigUnavailableError)
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
