require "rails_helper"
require_relative "../../support/current_amount_inspector_helpers"

RSpec.describe Admin::CurrentAmountInspectorPresenter do
  include CurrentAmountInspectorHelpers

  let(:profile) { current_amount_profile }
  subject(:presenter) { described_class.new(profile) }

  it "preserves stored current values, negative scores and candidate order without mutating input" do
    original = profile.deep_dup
    expect(ReceiptAmountService).not_to receive(:call)
    expect(presenter.state).to eq(:available)
    expect(presenter.selected_candidate.fetch("score")).to eq(-1)
    expect(presenter.candidates.map { |candidate| candidate["candidate_id"] }).to eq(
      profile.dig("amount_engine", "candidates").map { |candidate| candidate["candidate_id"] }
    )
    expect(presenter.data.fetch("resolved")).to eq(profile.fetch("resolved"))
    expect(profile).to eq(original)
  end

  [ nil, {} ].each do |value|
    it "distinguishes missing profile #{value.inspect}" do
      expect(described_class.new(value).state).to eq(:missing)
    end
  end

  [ [], "private payload", { "schema_version" => "1" }, { "schema_version" => 1.0 }, { "schema_version" => 2 } ].each do |value|
    it "refuses unsupported root shape #{value.class}" do
      result = described_class.new(value)
      expect(result.state).to eq(:unavailable)
      expect(result.data).to eq({})
    end
  end

  it "keeps manual and edit-save totals without inventing candidates" do
    %w[manual edit_save].each do |context|
      result = described_class.new(profile.except("amount_engine").merge("context" => context, "profile" => nil))
      expect(result.state).to eq(:available)
      expect(result.data["context"]).to eq(context)
      expect(result.data.fetch("computed")).to eq(profile.fetch("computed"))
      expect(result.candidates).to eq([])
      expect(result.engine_state).to eq(:missing)
    end
  end

  it "does not turn rejected selections, no-safe or absent candidates into acceptance" do
    profile["selected_candidate_status"] = "rejected"
    profile["amount_engine"]["no_safe_candidate"] = true
    profile["amount_engine"]["selected_candidate_status"] = "rejected"
    expect(presenter.data["selected_candidate_status"]).to eq("rejected")
    expect(presenter.data.dig("amount_engine", "no_safe_candidate")).to be(true)
    profile["amount_engine"]["candidates"] = []
    expect(described_class.new(profile).candidates).to eq([])
  end

  it "does not reclassify stored warnings or infer review outcomes" do
    expect(presenter.data["warnings"]).to eq([ "price_tax_inclusion_uncertain" ])
    expect(presenter.data).not_to have_key("review_required_warnings")
    expect(presenter.data).not_to have_key("diagnostic_warnings")
    expect(presenter.data["safe_to_auto_complete"]).to be(false)
  end

  it "quarantines unsupported nested versions without hiding current totals" do
    profile["amount_engine"]["schema_version"] = 99
    expect(presenter.engine_state).to eq(:unavailable)
    expect(presenter.data["resolved"]).to eq(profile["resolved"])
    expect(presenter.selected_candidate).to eq({})
    expect(presenter.candidates).to eq([])
  end

  it "allows exact bounded decimals but not coercion, exponent notation or special numbers" do
    candidate = profile.dig("amount_engine", "selected_candidate")
    candidate["computed_items"] = [
      {
        "quantity" => "123.456",
        "tax_rate" => "0.08",
        "price" => 0,
        "line_total" => "1e9",
        "discount_amount" => Float::INFINITY,
        "original_line_total" => { "secret" => "private" },
        "discount_rate" => "NaN"
      }
    ]
    expect(presenter.computed_items).to eq([ { "quantity" => "123.456", "tax_rate" => "0.08", "price" => 0 } ])
    expect(presenter.omitted?).to be(true)
  end

  it "keeps saved recurring derived decimals without rounding them for display" do
    rate = BigDecimal("1") / BigDecimal("3")
    snapshot = ReceiptAmountService.calculation_profile_snapshot({
      amount_engine: { schema_version: 1, selected_candidate: { computed_items: [ { discount_rate: rate } ] } }
    }).deep_stringify_keys
    expect(described_class.new(snapshot).computed_items).to eq([ { "discount_rate" => rate.to_s("F") } ])
  end

  it "filters private values even under recognized keys and does not traverse unknown payloads" do
    secret = "<script>private-secret@example.test</script>"
    profile["context"] = secret
    profile["raw_response"] = { "nested" => secret }
    candidate = profile.dig("amount_engine", "selected_candidate")
    candidate.merge!("candidate_id" => secret, "basis" => secret, "score" => secret, "product_name" => secret)
    candidate["evidence"] = [ { "source" => secret, "formula" => secret, "amount" => secret, "index" => -1 } ]
    candidate["warnings"] = [ secret ]
    expect(presenter.data.to_json).not_to include(secret, "raw_response", "product_name")
    expect(presenter.omitted?).to be(true)
  end

  it "refuses incompatible encodings and control characters without raising or dumping values" do
    [ "12".encode(Encoding::UTF_16BE), "\xFF".force_encoding(Encoding::UTF_8), "12\u0000", "12\n" ].each do |invalid|
      profile["amount_engine"]["selected_candidate"]["subtotal"] = invalid
      expect { described_class.new(profile) }.not_to raise_error
      result = described_class.new(profile)
      expect(result.selected_candidate).not_to have_key("subtotal")
      expect(result.omitted?).to be(true)
    end
  end

  it "bounds strings, arrays and output, and explicitly records omission" do
    candidate = profile.dig("amount_engine", "selected_candidate")
    candidate["score"] = 10**1000
    candidate["evidence"] = Array.new(1000) { { "source" => "receipt_items", "amount" => "9" * 1000 } }
    candidate["computed_items"] *= 1000
    profile["amount_engine"]["candidates"] = Array.new(1000) { candidate }
    expect(presenter.candidates.size).to be <= 20
    expect(presenter.evidence.size).to be <= 20
    expect(presenter.computed_items.size).to be <= 20
    expect(presenter.data.to_json.bytesize).to be < 60_000
    expect(presenter.omitted?).to be(true)
  end

  it "separates empty recorded reasons from missing and rejected invalid values" do
    expect(presenter.reasons([])).to eq([ I18n.t("admin.current_amount_inspector.none") ])
    expect(presenter.reasons(nil)).to eq([ I18n.t("admin.current_amount_inspector.not_recorded") ])
    profile["blocking_mismatch_codes"] = [ "PRIVATE_VALUE" ]
    result = described_class.new(profile)
    expect(result.data["blocking_mismatch_codes"]).to be_nil
    expect(result.omitted?).to be(true)
  end
end
