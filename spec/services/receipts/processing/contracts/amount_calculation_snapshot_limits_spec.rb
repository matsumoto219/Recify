require "rails_helper"

RSpec.describe Receipts::Processing::Contracts::AmountCalculationSnapshotLimits do
  let(:defaults) { { "max_bytes" => 131_072, "computed_items" => 100, "evidence" => 200, "candidates" => 3 } }

  it "承認済みの全上限を一括取得する" do
    expect(SystemSettings).to receive(:limits_for).once.and_call_original

    expect(described_class.capture).to eq(defaults)
  end

  it "新設定をhigh risk整数として定義し境界値と型を検証する" do
    {
      "limits.snapshot_amount_calculation_max_bytes" => [ 131_072, 131_072, 1_048_576 ],
      "limits.snapshot_amount_computed_items_max" => [ 100, 20, 10_000 ],
      "limits.snapshot_amount_evidence_max" => [ 200, 40, 10_000 ]
    }.each do |key, (default, minimum, maximum)|
      expect(SystemSettings.definition_for(key)).to have_attributes(
        value_type: "integer", category: "snapshot_limit", default: default,
        min: minimum, max: maximum, risk_level: "high", editable: true
      )
      expect(SystemSettings.cast_update_value(key, minimum.to_s)).to eq(minimum)
      expect(SystemSettings.cast_update_value(key, maximum.to_s)).to eq(maximum)
      [ minimum - 1, maximum + 1, "1.5", true, {} ].each do |invalid|
        expect { SystemSettings.cast_update_value(key, invalid) }.to raise_error(SystemSettings::ValidationError)
      end
    end
  end

  it "新規runだけ取得し待機runと同一runでは設定を取り直さない" do
    receipt = create(:receipt)
    first = Receipts::Processing::Runs.start(receipt: receipt, source: "upload").run
    create(:system_setting, key: "limits.snapshot_amount_evidence_max", value: { "value" => 400 })
    repeated = Receipts::Processing::Runs.start(receipt: receipt, source: "upload")

    expect(repeated.created).to be(false)
    expect(repeated.run.id).to eq(first.id)
    expect(described_class.from_metadata(first.reload.metadata)).to eq(defaults)

    next_run = Receipts::Processing::Runs.start(receipt: create(:receipt), source: "admin_retry", parent_run: first).run
    expect(described_class.from_metadata(next_run.metadata)).to eq(defaults.merge("evidence" => 400))
  end

  it "旧runと不正metadataへ現在値を補完しない" do
    expect(SystemSettings).not_to receive(:limits_for)
    [ {}, nil, [], { described_class::METADATA_KEY => defaults.merge("max_bytes" => "131072") } ].each do |metadata|
      expect(described_class.from_metadata(metadata)).to be_nil
    end
  end

  it "上限metadataの未知key・不足・範囲外を拒否する" do
    [ defaults.except("candidates"), defaults.merge("secret" => "hidden"), defaults.merge(secret: "hidden"), defaults.merge("candidates" => 21) ].each do |limits|
      expect(described_class.from_metadata(described_class::METADATA_KEY => limits)).to be_nil
    end
  end

  it "最大設定も損失なく読み戻す" do
    maximum = { "max_bytes" => 1_048_576, "computed_items" => 10_000, "evidence" => 10_000, "candidates" => 20 }
    expect(described_class.from_metadata(described_class::METADATA_KEY => maximum)).to eq(maximum)
  end
end
