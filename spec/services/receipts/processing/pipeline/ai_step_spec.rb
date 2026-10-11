require "rails_helper"

RSpec.describe Receipts::Processing::Pipeline::AiStep do
  let(:run) { Receipts::Processing.start(receipt: create(:receipt), source: "upload").run }
  let(:ocr_result) { { success: true, candidates: { items: [] } } }
  let(:ai_result) { { success: true, receipt_attributes: {}, receipt_items_attributes: [] } }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OPENAI_AI_MODEL").and_return("gpt-6-luna")
    allow(ExternalServices).to receive(:down?).with(:ai).and_return(false)
  end

  [ [ false, "low" ], [ true, "high" ] ].each do |enabled, effort|
    it "商品名補完#{enabled}のmodelとeffortをprovider前に保存する" do
      before_provider_call = -> do
        expect(run.reload.ai_input_snapshot.fetch("meta")).to include(
          "ai_name_completion_enabled" => enabled,
          "ai_execution" => { "schema_version" => 1, "model" => "gpt-6-luna", "reasoning_effort" => effort }
        )
      end
      allow(ReceiptAiEnrichmentService).to receive(:call) do |_ocr, **options|
        expect(options.fetch(:ai_name_completion_enabled)).to eq(enabled)
        expect(options.fetch(:runtime_config).model).to eq("gpt-6-luna")
        options.fetch(:capture_input).call(meta: { ai_name_completion_enabled: enabled })
        options.fetch(:before_provider_call).call
        ai_result
      end

      described_class.call(run:, ocr_result:, ai_name_completion_enabled: enabled, before_provider_call:)

      expect(ReceiptAiEnrichmentService).to have_received(:call).once
    end
  end

  it "既に保存した実行条件を同一runでは再選択しない" do
    allow(ReceiptAiEnrichmentService).to receive(:call) do |_ocr, **options|
      expect(options.fetch(:ai_name_completion_enabled)).to be(true)
      expect(options.fetch(:runtime_config)).to have_attributes(model: "gpt-6-luna", name_completion_reasoning_effort: "high")
      options.fetch(:capture_input).call(meta: { ai_name_completion_enabled: options.fetch(:ai_name_completion_enabled) })
      ai_result
    end
    described_class.call(run:, ocr_result:, ai_name_completion_enabled: true)
    original = run.reload.ai_input_snapshot.fetch("meta")
    allow(ENV).to receive(:[]).with("OPENAI_AI_MODEL").and_return("future-model")
    create(:system_setting, key: "external_services.ai.name_completion_reasoning_effort", value: SystemSettings.stored_value("xhigh"))

    described_class.call(run: run.reload, ocr_result:, ai_name_completion_enabled: false)

    expect(run.reload.ai_input_snapshot.fetch("meta")).to eq(original)
  end

  it "実行条件のsnapshotが不正ならproviderと利用量callbackへ進まない" do
    run.update!(ai_input_snapshot: { "meta" => {
      "ai_name_completion_enabled" => true,
      "ai_execution" => { "schema_version" => 1, "model" => "gpt-6-luna" }
    } })
    before_provider_call = spy("before_provider_call")
    allow(ReceiptAiEnrichmentService).to receive(:call)

    expect { described_class.call(run:, ocr_result:, before_provider_call:) }
      .to raise_error(ExternalServices::RuntimeConfigUnavailableError)

    aggregate_failures do
      expect(ReceiptAiEnrichmentService).not_to have_received(:call)
      expect(before_provider_call).not_to have_received(:call)
    end
  end

  it "実行条件の保存失敗後はprovider前callbackへ進まない" do
    allow(Receipts::Processing).to receive(:record_ai_input).and_raise(ActiveRecord::RecordInvalid)
    before_provider_call = spy("before_provider_call")
    allow(ReceiptAiEnrichmentService).to receive(:call) do |_ocr, **options|
      options.fetch(:capture_input).call(meta: { ai_name_completion_enabled: false })
      options.fetch(:before_provider_call).call
      ai_result
    end

    expect { described_class.call(run:, ocr_result:, before_provider_call:) }
      .to raise_error(ActiveRecord::RecordInvalid)
    expect(before_provider_call).not_to have_received(:call)
  end

  it "AI停止中はruntime configを取得せずproviderとcounterを使わない" do
    run
    allow(ExternalServices).to receive(:down?).with(:ai).and_return(true)
    allow(ExternalServices).to receive(:unavailable_detail).and_return(nil)
    allow(Receipts::Processing).to receive(:external_service_runtime_config)
    allow(ReceiptAiEnrichmentService).to receive(:call)
    before_provider_call = spy("before_provider_call")

    described_class.call(run:, ocr_result:, before_provider_call:)

    aggregate_failures do
      expect(Receipts::Processing).not_to have_received(:external_service_runtime_config)
      expect(ReceiptAiEnrichmentService).not_to have_received(:call)
      expect(before_provider_call).not_to have_received(:call)
      expect(run.reload.ai_input_snapshot).to eq({})
    end
  end
end
