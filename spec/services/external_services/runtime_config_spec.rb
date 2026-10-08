require "rails_helper"

RSpec.describe ExternalServices::RuntimeConfig do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OPENAI_AI_MODEL").and_return(nil)
  end

  describe ".openai_model_name" do
    it "未指定と空白のmodelは共通の既定値を使う" do
      aggregate_failures do
        expect(described_class.openai_model_name(env: {})).to eq("gpt-6-luna")
        expect(described_class.openai_model_name(env: { "OPENAI_AI_MODEL" => "  " })).to eq("gpt-6-luna")
      end
    end

    it "modelをtrimし未対応の名前でもcapability判定は行わない" do
      expect(described_class.openai_model_name(env: { "OPENAI_AI_MODEL" => " future-model-2027 " }))
        .to eq("future-model-2027")
    end

    [
      [ "不正型", 123 ],
      [ "制御文字", "model\nprivate" ],
      [ "secret形式", "sk-notarealtestcredential" ],
      [ "非ASCII", "モデル" ],
      [ "500bytes超過", "m" * 501 ]
    ].each do |label, model|
      it "#{label}のmodelは安全な固定エラーで拒否する" do
        expect { described_class.openai_model_name(env: { "OPENAI_AI_MODEL" => model }) }
          .to raise_error(ArgumentError, "invalid_ai_model")
      end
    end
  end

  describe ".load" do
    it "SystemSettingsの既定値からimmutableな設定snapshotを作る" do
      snapshot = described_class.load

      aggregate_failures do
        expect(snapshot).to be_frozen
        expect(snapshot.ai).to be_frozen
        expect(snapshot.ocr).to be_frozen
        expect(snapshot.ai).to have_attributes(
          open_timeout_seconds: 10,
          read_timeout_seconds: 120,
          max_elapsed_seconds: 600,
          max_retries: 2,
          base_retry_delay_seconds: 1.0,
          max_retry_delay_seconds: 10.0,
          model: "gpt-6-luna",
          reasoning_effort: "low",
          name_completion_reasoning_effort: "high"
        )
        expect(snapshot.ocr).to have_attributes(
          request_timeout_seconds: 30,
          max_elapsed_seconds: 180,
          max_poll_attempts: 20,
          poll_interval_seconds: 1.0,
          poll_backoff_factor: 1.5,
          max_poll_interval_seconds: 3.0,
          max_retries: 2,
          base_retry_delay_seconds: 0.5,
          max_retry_delay_seconds: 10.0
        )
      end
    end

    it "modelと両effortを取得し同じbatchで数値設定と固定する" do
      allow(ENV).to receive(:[]).with("OPENAI_AI_MODEL").and_return("future-model")
      create(:system_setting, key: "external_services.ai.reasoning_effort", value: SystemSettings.stored_value("none"))
      create(:system_setting, key: "external_services.ai.name_completion_reasoning_effort", value: SystemSettings.stored_value("xhigh"))
      allow(SystemSettings).to receive(:values_for).and_call_original

      snapshot = described_class.load

      aggregate_failures do
        expect(snapshot.ai).to have_attributes(model: "future-model", reasoning_effort: "none", name_completion_reasoning_effort: "xhigh")
        expect(SystemSettings).to have_received(:values_for).with(
          SystemSettings::EXTERNAL_SERVICE_RUNTIME_TUNING_KEYS + %w[external_services.ai.reasoning_effort external_services.ai.name_completion_reasoning_effort]
        ).once
        expect(snapshot.serializable_hash).to include("schema_version" => 1, "ai_execution_config_version" => 1)
      end
    end

    it "DBに保存されたSystemSettingsを既定値より優先する" do
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

      expect(described_class.load.ai.read_timeout_seconds).to eq(300)
    end
  end

  describe ".deserialize" do
    it "保存用hashから同じsnapshotを復元する" do
      snapshot = described_class.load

      expect(described_class.deserialize(snapshot.serializable_hash)).to eq(snapshot)
    end

    it "500bytesの安全なmodelを短縮せずimmutableに往復する" do
      model = "m" * 500
      allow(ENV).to receive(:[]).with("OPENAI_AI_MODEL").and_return(model)
      snapshot = described_class.load

      restored = described_class.deserialize(snapshot.serializable_hash)

      aggregate_failures do
        expect(restored.ai.model).to eq(model)
        expect(restored.ai.model).to be_frozen
        expect(restored.ai.reasoning_effort).to be_frozen
        expect(restored.ai.name_completion_reasoning_effort).to be_frozen
      end
    end

    it "保存済みの不正modelをsanitizeや既定値への置換で補修しない" do
      value = described_class.load.serializable_hash
      value.fetch("ai")["model"] = "sk-notarealtestcredential"
      allow(Rails.logger).to receive(:error)

      expect { ExternalServices.deserialize_runtime_config_snapshot(value) }
        .to raise_error(ExternalServices::RuntimeConfigUnavailableError, "external_service_runtime_config_unavailable")
      expect(Rails.logger).to have_received(:error).with("[ExternalServices] runtime_config_snapshot_invalid class=ArgumentError").once
    end

    it "新AI設定のない旧timing snapshotは新値を推測せず復元する" do
      value = described_class.load.serializable_hash
      value.delete("ai_execution_config_version")
      value.fetch("ai").except!("model", "reasoning_effort", "name_completion_reasoning_effort")

      snapshot = described_class.deserialize(value)

      aggregate_failures do
        expect(snapshot.ai).to have_attributes(model: nil, reasoning_effort: nil, name_completion_reasoning_effort: nil)
        expect(snapshot.serializable_hash).to eq(value)
      end
    end

    [ "model", "reasoning_effort", "name_completion_reasoning_effort" ].each do |key|
      it "新AI設定の#{key}だけ欠けたsnapshotは拒否する" do
        value = described_class.load.serializable_hash
        value.fetch("ai").delete(key)

        expect { described_class.deserialize(value) }.to raise_error(ArgumentError)
      end
    end

    it "新AI設定があるのにlocal versionが欠けたsnapshotは拒否する" do
      value = described_class.load.serializable_hash
      value.delete("ai_execution_config_version")

      expect { described_class.deserialize(value) }.to raise_error(ArgumentError)
    end

    [ nil, 1, "unknown" ].each do |effort|
      it "不正なeffort #{effort.inspect}を拒否する" do
        value = described_class.load.serializable_hash
        value.fetch("ai")["reasoning_effort"] = effort

        expect { described_class.deserialize(value) }.to raise_error(ArgumentError)
      end
    end

    it "schema_versionが不正なら拒否する" do
      value = described_class.load.serializable_hash.merge("schema_version" => 99)

      expect { described_class.deserialize(value) }
        .to raise_error(ArgumentError, "invalid_runtime_config_schema")
    end
  end
end
