require "rails_helper"

RSpec.describe "External service tuning SystemSettings" do
  describe "definitions" do
    it "全keyをhigh-riskの編集可能設定として定義する" do
      definitions = SystemSettings::EXTERNAL_SERVICE_RUNTIME_TUNING_KEYS.map do |key|
        SystemSettings.definition_for(key)
      end

      expect(definitions).to all(
        have_attributes(
          category: "external_service_tuning",
          editable: true,
          risk_level: "high"
        )
      )
    end

    it "AI read timeoutを900秒まで設定可能にする" do
      definition = SystemSettings.definition_for("external_services.ai.read_timeout_seconds")

      expect(definition).to have_attributes(default: 120, min: 15, max: 900)
    end
  end

  describe "AI dependencies" do
    it "open timeoutがread timeoutを超える設定を拒否する" do
      create(
        :system_setting,
        key: "external_services.ai.read_timeout_seconds",
        value: SystemSettings.stored_value(15)
      )

      expect do
        SystemSettings.cast_update_value("external_services.ai.open_timeout_seconds", 60)
      end.to raise_error(SystemSettings::ValidationError, SystemSettings::AI_TIMEOUT_ORDER_ERROR)
    end

    it "base retry delayがmax retry delayを超える設定を拒否する" do
      expect do
        SystemSettings.cast_update_value("external_services.ai.base_retry_delay_seconds", 20)
      end.to raise_error(SystemSettings::ValidationError, SystemSettings::AI_RETRY_DELAY_ORDER_ERROR)
    end

    it "全試行時間見積りがmax elapsedを超える設定を拒否する" do
      expect do
        SystemSettings.cast_update_value("external_services.ai.read_timeout_seconds", 300)
      end.to raise_error(SystemSettings::ValidationError, SystemSettings::AI_ELAPSED_BUDGET_ERROR)
    end

    it "max elapsedを先に上げれば長いread timeoutを許可する" do
      create(
        :system_setting,
        key: "external_services.ai.max_elapsed_seconds",
        value: SystemSettings.stored_value(1200)
      )
      create(
        :system_setting,
        key: "external_services.ai.max_retries",
        value: SystemSettings.stored_value(0)
      )

      expect(SystemSettings.cast_update_value("external_services.ai.read_timeout_seconds", 900)).to eq(900)
    end
  end

  describe "OCR dependencies" do
    it "request timeoutがmax elapsedを超える設定を拒否する" do
      expect do
        SystemSettings.cast_update_value("external_services.ocr.request_timeout_seconds", 200)
      end.to raise_error(SystemSettings::ValidationError, SystemSettings::OCR_TIMEOUT_BUDGET_ERROR)
    end

    it "poll intervalがmax poll intervalを超える設定を拒否する" do
      expect do
        SystemSettings.cast_update_value("external_services.ocr.poll_interval_seconds", 4)
      end.to raise_error(SystemSettings::ValidationError, SystemSettings::OCR_POLL_INTERVAL_ORDER_ERROR)
    end

    it "base retry delayがmax retry delayを超える設定を拒否する" do
      expect do
        SystemSettings.cast_update_value("external_services.ocr.base_retry_delay_seconds", 20)
      end.to raise_error(SystemSettings::ValidationError, SystemSettings::OCR_RETRY_DELAY_ORDER_ERROR)
    end

    it "poll待機とretry系列がmax elapsedを超える設定を拒否する" do
      expect do
        SystemSettings.cast_update_value("external_services.ocr.max_poll_attempts", 40)
      end.to raise_error(SystemSettings::ValidationError, SystemSettings::OCR_ELAPSED_BUDGET_ERROR)
    end

    it "max elapsedを先に上げればpoll上限を増やせる" do
      create(
        :system_setting,
        key: "external_services.ocr.max_elapsed_seconds",
        value: SystemSettings.stored_value(300)
      )

      expect(SystemSettings.cast_update_value("external_services.ocr.max_poll_attempts", 40)).to eq(40)
    end
  end
end
