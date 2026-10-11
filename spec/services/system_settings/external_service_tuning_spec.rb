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

      expect(definition).to have_attributes(default: 300, min: 15, max: 900)
    end

    it "全keyのdefaultと安全範囲を固定する" do
      expected_ranges = {
        "external_services.ai.open_timeout_seconds" => [ 10, 1, 60 ],
        "external_services.ai.read_timeout_seconds" => [ 300, 15, 900 ],
        "external_services.ai.max_elapsed_seconds" => [ 1200, 60, 3600 ],
        "external_services.ai.max_retries" => [ 2, 0, 3 ],
        "external_services.ai.base_retry_delay_seconds" => [ 1.0, 0.1, 30.0 ],
        "external_services.ai.max_retry_delay_seconds" => [ 10.0, 0.1, 120.0 ],
        "external_services.ocr.request_timeout_seconds" => [ 30, 1, 300 ],
        "external_services.ocr.max_elapsed_seconds" => [ 180, 30, 1200 ],
        "external_services.ocr.max_poll_attempts" => [ 20, 1, 300 ],
        "external_services.ocr.poll_interval_seconds" => [ 1.0, 0.25, 30.0 ],
        "external_services.ocr.poll_backoff_factor" => [ 1.5, 1.0, 5.0 ],
        "external_services.ocr.max_poll_interval_seconds" => [ 3.0, 0.25, 120.0 ],
        "external_services.ocr.max_retries" => [ 2, 0, 3 ],
        "external_services.ocr.base_retry_delay_seconds" => [ 0.5, 0.1, 30.0 ],
        "external_services.ocr.max_retry_delay_seconds" => [ 10.0, 0.1, 120.0 ]
      }

      actual_ranges = expected_ranges.keys.to_h do |key|
        definition = SystemSettings.definition_for(key)
        [ key, [ definition.default, definition.min, definition.max ] ]
      end

      expect(actual_ranges).to eq(expected_ranges)
    end
  end

  describe "AI reasoning effort" do
    {
      "external_services.ai.reasoning_effort" => "low",
      "external_services.ai.name_completion_reasoning_effort" => "high"
    }.each do |key, default|
      context key do
        it "high-riskの編集可能enumとして既定値と確認必須を定義する" do
          definition = SystemSettings.definition_for(key)

          aggregate_failures do
            expect(definition).to have_attributes(
              category: "external_service_tuning",
              value_type: "enum",
              default: default,
              allowed_values: %w[none low medium high xhigh max],
              editable: true,
              risk_level: "high",
              requires_confirmation: true
            )
            expect(SystemSettings.value_for(key)).to eq(default)
          end
        end

        %w[none low medium high xhigh max].each do |value|
          it "#{value}を許可する" do
            expect(SystemSettings.cast_update_value(key, value)).to eq(value)
          end
        end

        [ nil, "", "LOW", "minimal", "unknown" ].each do |value|
          it "#{value.inspect}を拒否する" do
            expect do
              SystemSettings.cast_update_value(key, value)
            end.to raise_error(SystemSettings::ValidationError, "invalid_enum")
          end
        end
      end
    end
  end

  describe "AI dependencies" do
    it "既定値はretry回数を変えずtimeout系列の時間を確保する" do
      aggregate_failures do
        expect(SystemSettings.cast_update_value("external_services.ai.read_timeout_seconds", 300)).to eq(300)
        expect(SystemSettings.value_for("external_services.ai.max_retries")).to eq(2)
      end
    end

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

    it "保存済みの短いmax elapsedを超えるread timeoutへの変更を拒否する" do
      create(:system_setting, key: "external_services.ai.read_timeout_seconds", value: SystemSettings.stored_value(120))
      create(:system_setting, key: "external_services.ai.max_elapsed_seconds", value: SystemSettings.stored_value(600))
      error = nil

      expect do
        SystemSettings.cast_update_value("external_services.ai.read_timeout_seconds", 300)
      end.to raise_error(SystemSettings::ValidationError) { |raised_error| error = raised_error }

      aggregate_failures do
        expect(error.message).to eq(SystemSettings::AI_ELAPSED_BUDGET_ERROR)
        expect(error.details).to include(required_seconds: 950)
      end
    end

    it "read上限でもretry回数を下げず必要なmax elapsedを設定できる" do
      elapsed = SystemSettings.cast_update_value("external_services.ai.max_elapsed_seconds", 2750)
      create(:system_setting, key: "external_services.ai.max_elapsed_seconds", value: SystemSettings.stored_value(elapsed))
      read_timeout = SystemSettings.cast_update_value("external_services.ai.read_timeout_seconds", 900)
      create(:system_setting, key: "external_services.ai.read_timeout_seconds", value: SystemSettings.stored_value(read_timeout))

      aggregate_failures do
        expect(SystemSettings.value_for("external_services.ai.max_retries")).to eq(2)
        expect(SystemSettings.cast_update_value("external_services.ai.max_elapsed_seconds", 3600)).to eq(3600)
        expect do
          SystemSettings.cast_update_value("external_services.ai.max_elapsed_seconds", 2749)
        end.to raise_error(SystemSettings::ValidationError, SystemSettings::AI_ELAPSED_BUDGET_ERROR)
      end
    end

    {
      "external_services.ai.read_timeout_seconds" => { 14 => "below_min", 901 => "above_max" },
      "external_services.ai.max_elapsed_seconds" => { 59 => "below_min", 3601 => "above_max" }
    }.each do |key, values|
      values.each do |value, reason|
        it "#{key}の範囲外#{value}を拒否する" do
          expect { SystemSettings.cast_update_value(key, value) }.to raise_error(SystemSettings::ValidationError, reason)
        end
      end
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
      error = nil

      expect do
        SystemSettings.cast_update_value("external_services.ocr.poll_interval_seconds", 4)
      end.to raise_error(SystemSettings::ValidationError) { |raised_error| error = raised_error }

      aggregate_failures do
        expect(error.message).to eq(SystemSettings::OCR_POLL_INTERVAL_ORDER_ERROR)
        expect(error.details).to include(required_seconds: 4)
      end
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
