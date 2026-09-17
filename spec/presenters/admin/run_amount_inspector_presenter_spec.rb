require "rails_helper"
require_relative "../../support/run_amount_inspector_helpers"

RSpec.describe Admin::RunAmountInspectorPresenter do
  include RunAmountInspectorHelpers

  it "run診断・保存profile・Receipt状態を区別し、選択候補の参照を解決する" do
    snapshot = run_amount_snapshot
    presenter = described_class.new(snapshot)

    aggregate_failures do
      expect(presenter.state).to eq(:available)
      expect(presenter.data.dig("computed", "total_amount")).to eq(1100)
      expect(presenter.candidates.first).to eq(presenter.selected_candidate)
      expect(presenter.review).to include("needs_review" => true, "warning_classification" => "unrecorded")
      expect(presenter.saved_profile.dig("computed", "total_amount")).to eq(1100)
      expect(presenter.receipt_summary).to include("status" => "review_needed")
      expect(presenter.candidates.last.fetch("evidence")).to be_present
      expect(presenter.omitted?).to be(false)
      expect(snapshot.dig("engine", "amount_engine", "candidates", 0)).to include("selected_candidate_ref" => true)
    end
  end

  it "旧run・未知version・不正値を現在profileへfallbackせず利用不可にする" do
    [ nil, {}, run_amount_snapshot.merge("schema_version" => "unknown"), run_amount_snapshot.merge("secret" => "PRIVATE") ].each do |snapshot|
      presenter = described_class.new(snapshot)
      expect(presenter.state).to eq(:unavailable)
      expect(presenter.data).to be_empty
    end
  end

  it "保存時の上限を保持し現在設定を参照しない" do
    expect(SystemSettings).not_to receive(:limit_for)
    expect(SystemSettings).not_to receive(:limits_for)
    presenter = described_class.new(run_amount_snapshot)

    expect(presenter.limits).to eq("max_bytes" => 131_072, "computed_items" => 100, "evidence" => 200, "candidates" => 3)
  end

  it "serializerが記録した全ての省略対象に表示ラベルがある" do
    presenter = described_class.new(run_amount_snapshot)

    aggregate_failures do
      expect(presenter.omissions.map { |entry| entry.fetch("path") }).to include("candidates")
      expect(presenter.omission_label("candidates")).to eq("比較候補")
      presenter.omissions.each do |entry|
        expect(presenter.omission_label(entry.fetch("path"))).not_to match(/translation missing/i)
      end
    end
  end
end
