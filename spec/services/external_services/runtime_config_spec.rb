require "rails_helper"

RSpec.describe ExternalServices::RuntimeConfig do
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
          max_retry_delay_seconds: 10.0
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

    it "schema_versionが不正なら拒否する" do
      value = described_class.load.serializable_hash.merge("schema_version" => 99)

      expect { described_class.deserialize(value) }
        .to raise_error(ArgumentError, "invalid_runtime_config_schema")
    end
  end
end
