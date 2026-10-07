require "rails_helper"

RSpec.describe Analysis::PurchasedAtEvidence do
  def candidate(index = 0, role: "unknown", **attributes)
    {
      candidate_id: "datetime_line_#{index}", source_path: "lines[#{index}]", line_index: index,
      date: "2026-09-01", time: "07:36", precision: "datetime", role:, association: "exact"
    }.merge(attributes)
  end

  def envelope(candidates = [ candidate ], **attributes)
    {
      schema_version: "purchased_at_evidence_v1", candidates:, complete: true,
      truncated: false, omitted_count: 0, invalid: false
    }.merge(attributes)
  end

  it "日時と役割をexactに往復し、入力を変更せずimmutableにする" do
    input = envelope
    original = input.deep_dup
    result = described_class.call(JSON.parse(input.to_json))

    expect(result).to eq(input)
    expect(result).to be_frozen
    expect(result[:candidates].first).to be_frozen
    expect(input).to eq(original)
  end

  it "日付だけと印字された午前0時を区別する" do
    date_only = candidate.except(:time).merge(precision: "date_only")
    midnight = candidate(1, time: "00:00")

    expect(described_class.call(envelope([ date_only, midnight ]))[:candidates]).to eq([ date_only, midnight ])
  end

  it "候補を省略しても既知の競合と不完全状態を失わない" do
    first = described_class.call(envelope([ candidate, candidate(1, time: "08:00") ]), max_candidates: 1)
    second = described_class.call(JSON.parse(first.to_json), max_candidates: 10)

    expect(first).to include(complete: false, truncated: true, omitted_count: 1)
    expect(second).to eq(first)
  end

  it "除外役割より購入対象を優先し、既知の除外候補省略だけで競合を作らない" do
    input = envelope([ candidate(role: "service_start"), candidate(1, role: "settlement") ])
    result = described_class.call(input, max_candidates: 1)

    expect(result[:candidates].map { |entry| entry[:role] }).to eq([ "settlement" ])
    expect(result).to include(complete: true, truncated: true, omitted_count: 1)
  end

  it "未知形式、不正日時、raw field、重複identityを拒否する" do
    invalid = [
      envelope(schema_version: "unknown"),
      envelope([ candidate(date: "2026-02-30") ]),
      envelope([ candidate(time: "24:00") ]),
      envelope([ candidate(raw_text: "private") ]),
      envelope([ candidate(role: "other") ]),
      envelope([ candidate, candidate ]),
      envelope(omitted_count: -1),
      envelope(complete: "true")
    ]

    invalid.each do |value|
      expect(described_class.call(value)).to include(candidates: [], complete: false, invalid: true)
    end
  end

  it "型とbyte上限を超えた入力とunknown index typeを拒否する" do
    invalid = [
      envelope(Array.new(51) { |index| candidate(index) }),
      envelope([ candidate(source_path: "x" * 200) ]),
      envelope([ candidate(span: { offset: -1, length: 1 }, string_index_type: "textElements") ]),
      envelope([ candidate(span: { offset: 0, length: 10 }, string_index_type: "unknown") ])
    ]

    invalid.each do |value|
      expect(described_class.call(value)[:invalid]).to be(true)
    end
    expect(described_class.call(nil)).to be_nil
  end

  it "legacy行からも同じ役割と精度を作り、日付を別イベントから借用しない" do
    result = described_class.from_lines(
      lines: [ "入庫 2026/09/01 23:50", "精算 00:10", "駐車時間 0:20" ],
      profile: ReceiptAnalysisProfiles.default
    )

    expect(result[:candidates].map { |entry| entry[:role] }).to eq(%w[service_start settlement duration])
    expect(result[:candidates][1]).to include(time: "00:10", precision: "time_only")
    expect(result[:candidates][1]).not_to have_key(:date)
  end

  it "同じ精算ブロックの日付と時刻がそれぞれlabelと値の行に分かれていても対応を保持する" do
    result = described_class.from_lines(
      lines: [ "精算日", "2026/09/01", "精算時刻", "07:36" ],
      profile: ReceiptAnalysisProfiles.default
    )

    expect(result[:candidates]).to contain_exactly(
      include(
        date: "2026-09-01", time: "07:36", precision: "datetime", role: "settlement",
        association: "exact", time_path: "lines[3]"
      )
    )
  end

  [ 0, 50 ].each do |purchase_index|
    it "購入候補が#{purchase_index}行目でも除外候補だけの上限省略では確定根拠を失わない" do
      lines = Array.new(50, "営業時間 10:00〜21:00")
      lines.insert(purchase_index, "精算 2026/09/01 07:36")

      result = described_class.from_lines(lines: lines, profile: ReceiptAnalysisProfiles.default)

      expect(result).to include(complete: true, truncated: true, omitted_count: 1, invalid: false)
      expect(result[:candidates].size).to eq(50)
      expect(result[:candidates]).to include(
        include(line_index: purchase_index, date: "2026-09-01", time: "07:36", role: "settlement")
      )
      expected_indexes = purchase_index.zero? ? (0..49).to_a : (0..48).to_a + [ 50 ]
      expect(result[:candidates].map { |entry| entry[:line_index] }).to eq(expected_indexes)
      expect(described_class.call(JSON.parse(result.to_json))).to eq(result)
    end
  end

  [ "精算 ", "" ].each do |label|
    it "ラベル#{label.inspect}の購入候補自体が上限を超えた場合は省略後も不完全状態を維持する" do
      lines = Array.new(51) { |index| "#{label}2026/09/01 07:#{index.to_s.rjust(2, '0')}" }

      result = described_class.from_lines(lines: lines, profile: ReceiptAnalysisProfiles.default)

      expect(result).to include(complete: false, truncated: true, omitted_count: 1, invalid: false)
      expect(result[:candidates].size).to eq(50)
      expect(described_class.call(JSON.parse(result.to_json))).to eq(result)
    end
  end

  it "省略された除外候補の対応が不正なら不完全状態を維持する" do
    lines = [ "精算 2026/09/01 07:36" ] + Array.new(50, "営業時間 10:00〜21:00")
    sources = lines.each_index.map do |index|
      { candidate_id: "datetime_line_#{index}", source_path: "lines[#{index}]", association: "exact" }
    end
    sources.last[:association] = "invalid"

    result = described_class.from_lines(lines: lines, profile: ReceiptAnalysisProfiles.default, line_sources: sources)

    expect(result).to include(complete: false, truncated: true, omitted_count: 1, invalid: false)
    expect(result[:candidates].size).to eq(50)
    expect(described_class.call(JSON.parse(result.to_json))).to eq(result)
  end
end
