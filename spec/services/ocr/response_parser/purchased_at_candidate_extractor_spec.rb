require "rails_helper"

RSpec.describe Ocr::ResponseParser::PurchasedAtCandidateExtractor do
  let(:profile) { ReceiptAnalysisProfiles.default }

  def extract(fields: {}, lines: [], profile: self.profile)
    described_class.call(fields:, lines:, profile:)
  end

  def layout(lines, positions: nil)
    offset = 0
    entries = lines.each_with_index.map do |text, index|
      x, y, width = positions&.fetch(index) || [ 0, index * 2, 20 ]
      line = {
        "content" => text, "spans" => [ { "offset" => offset, "length" => text.length } ],
        "polygon" => [ x, y, x + width, y, x + width, y + 1, x, y + 1 ]
      }
      offset += text.length + 1
      line
    end
    { "content" => lines.join("\n"), "stringIndexType" => "textElements", "pages" => [ { "lines" => entries } ] }
  end

  describe "イベントに対応する購入日時" do
    it "入庫・精算・経過時間を別の役割として保持し精算を採用する" do
      result = described_class.extract(
        fields: { "TransactionDate" => { "valueDate" => "2026-09-01" }, "TransactionTime" => { "valueTime" => "06:08" } },
        lines: [ "入庫時刻", "2026年9月1日 06:08", "精算時刻", "2026年9月1日 07:36", "駐車時間", "1:28" ],
        profile:
      )

      aggregate_failures do
        expect(result[:purchased_at_text]).to eq("2026-09-01 07:36")
        expect(result[:purchased_at_evidence][:candidates].map { |entry| entry[:role] }).to eq(%w[service_start settlement duration])
      end
    end

    it "日付だけと明示00:00を区別して保持する" do
      result = described_class.extract(fields: {}, lines: [ "購入日 2026/09/01" ], profile:)

      aggregate_failures do
        expect(result[:purchased_at_evidence][:candidates].first).to include(date: "2026-09-01", precision: "date_only")
        expect(result[:purchased_at_text]).to eq("2026-09-01")
      end
    end

    it "精算予定・再発行・入庫券発行だけから購入日時を作らない" do
      [ "精算予定", "再発行", "入庫券発行" ].each do |label|
        expect(described_class.call(fields: {}, lines: [ "#{label} 2026/09/01 07:36" ], profile:)).to be_nil
      end
    end
  end

  it "structured日時が不正なら確定値として採用しない" do
    fields = {
      "TransactionDate" => { "valueDate" => "2026/99/40" },
      "TransactionTime" => { "valueTime" => "25:99:00" }
    }

    expect(extract(fields:)).to be_nil
  end

  it "空のstructured日付から仮の日付を作らず時刻だけを保持する" do
    fields = {
      "TransactionDate" => { "valueDate" => "" },
      "TransactionTime" => { "valueTime" => "18:42" }
    }

    expect(extract(fields:)).to eq("18:42")
  end

  it "同一行の日時を一組としてcalendarとclockを正規化する" do
    lines = [ "2026 / 05 / 20 9 ： 05" ]

    expect(extract(lines:)).to eq("2026-05-20 09:05")
  end

  it "日付直後の独立した時刻を同じイベントとして結び、別時刻を近さだけで優先しない" do
    aggregate_failures do
      expect(extract(lines: [ "2026/05/20", "10:00" ])).to eq("2026-05-20 10:00")
      expect(extract(lines: [ "2026/05/20 10:00", "2026/05/20 11:00" ])).to be_nil
      expect(extract(lines: [ "2026/05/20", "レジ 0796", "0796 16時41分" ])).to eq("2026-05-20 16:41")
      expect(extract(lines: [ "2026/05/20", "商品区分", "0796 16時41分" ])).to eq("2026-05-20")
      expect(extract(lines: [ "2026/05/20", "商品区分", "16:41", "17:00" ])).to eq("2026-05-20")
      expect(extract(lines: [ "2026/05/20", "入庫", "16:41" ])).to eq("2026-05-20")
    end
  end

  it "日付があれば遠方時刻を探索せず、時刻のみが一意なら時刻として保持する" do
    aggregate_failures do
      expect(extract(lines: [ "2026/05/20", "商品", "小計", "合計", "18:42" ])).to eq("2026-05-20")
      expect(extract(lines: [ "9:05" ])).to eq("09:05")
      expect(extract(lines: [ "9:05", "10:15" ])).to be_nil
    end
  end

  it "profileから注入された日付patternだけを使用する" do
    custom_profile = double(
      "receipt analysis profile",
      ocr_purchased_at_date_patterns: [ /custom\s*\d{4}-\d{2}-\d{2}/ ],
      ocr_purchased_at_time_pattern: /(\d{1,2}):(\d{2})(?::(\d{2}))?/,
      ocr_purchased_at_role_patterns: { "settlement" => /paid/, "service_start" => /arrival/ }
    )

    expect(extract(lines: [ "2026/05/20", "paid custom 2026-05-21" ], profile: custom_profile)).to eq("2026-05-21")
  end

  it "calendarとして不正な日付を拒否する" do
    expect(extract(lines: [ "2026/99/99" ])).to be_nil
  end

  it "日時候補がなければnilを返し、入力を変更しない" do
    fields = { "TransactionDate" => { "valueDate" => nil } }
    lines = [ "店舗", "合計 100" ]
    original_fields = fields.deep_dup
    original_lines = lines.deep_dup

    result = extract(fields:, lines:)

    aggregate_failures do
      expect(result).to be_nil
      expect(fields).to eq(original_fields)
      expect(lines).to eq(original_lines)
    end
  end

  it "malformed fieldは安全に拒否しprofile contract errorは握り潰さない" do
    aggregate_failures do
      expect(extract(fields: "invalid")).to be_nil
      expect { extract(lines: [ "2026/05/20" ], profile: Object.new) }.to raise_error(NoMethodError)
    end
  end

  it "別行の入庫・精算labelをexactなprovider spanで区別する" do
    lines = [ "入庫時刻", "2026年9月1日 06:08", "精算時刻", "2026年9月1日 07:36", "駐車時間", "1:28" ]
    response = layout(lines)
    source = response["pages"].first["lines"][1]
    fields = {
      "TransactionDate" => { "valueDate" => "2026-09-01", "spans" => source["spans"] },
      "TransactionTime" => { "valueTime" => "06:08", "spans" => source["spans"] }
    }
    result = described_class.extract(fields:, lines:, profile:, analyze_result: response)

    aggregate_failures do
      expect(result[:purchased_at_text]).to eq("2026-09-01 07:36")
      expect(result[:purchased_at_evidence][:candidates].map { |entry| entry[:role] }).to eq(%w[service_start settlement duration])
      expect(result[:purchased_at_evidence][:candidates][1]).to include(
        source_path: "pages[0].lines[3]", label_path: "pages[0].lines[2]", string_index_type: "textElements"
      )
    end
  end

  it "左右列のlabelとvalueをOCR配列順から混ぜない" do
    lines = [ "入庫時刻", "精算時刻", "2026/09/01 06:08", "2026/09/01 07:36" ]
    positions = [ [ 0, 0, 6 ], [ 20, 0, 6 ], [ 0, 2, 12 ], [ 20, 2, 12 ] ]
    result = described_class.extract(fields: {}, lines:, profile:, analyze_result: layout(lines, positions:))

    aggregate_failures do
      expect(result[:purchased_at_text]).to eq("2026-09-01 07:36")
      expect(result[:purchased_at_evidence][:candidates].map { |entry| entry[:role] }).to eq(%w[service_start settlement])
      expect(extract(lines:)).to be_nil
    end
  end

  it "同じ高さで分離したlabelとvalueを一つのイベントとして関連付ける" do
    lines = [ "精算時刻", "2026/09/01 07:36" ]
    positions = [ [ 0, 0, 5 ], [ 7, 0, 15 ] ]
    result = described_class.extract(fields: {}, lines:, profile:, analyze_result: layout(lines, positions:))

    aggregate_failures do
      expect(result[:purchased_at_text]).to eq("2026-09-01 07:36")
      expect(result[:purchased_at_evidence][:candidates].first[:role]).to eq("settlement")
    end
  end

  it "右寄せの経過時間も一意なrowへ関連付け購入時刻から除外する" do
    lines = [ "精算時刻", "2026/09/01 07:36", "駐車時間", "1:28" ]
    positions = [ [ 0, 0, 5 ], [ 7, 0, 15 ], [ 0, 2, 5 ], [ 30, 2, 3 ] ]
    result = described_class.extract(fields: {}, lines:, profile:, analyze_result: layout(lines, positions:))

    aggregate_failures do
      expect(result[:purchased_at_text]).to eq("2026-09-01 07:36")
      expect(result[:purchased_at_evidence][:complete]).to be(true)
      expect(result[:purchased_at_evidence][:candidates].last[:role]).to eq("duration")
    end
  end

  it "同じrowの隣接した別イベントを水平距離だけで借用しない" do
    lines = [ "入庫時刻", "2026/09/01 06:08", "精算時刻", "2026/09/01 07:36" ]
    positions = [ [ 0, 0, 5 ], [ 7, 0, 15 ], [ 25, 0, 5 ], [ 32, 0, 15 ] ]
    result = described_class.extract(fields: {}, lines:, profile:, analyze_result: layout(lines, positions:))

    aggregate_failures do
      expect(result[:purchased_at_text]).to eq("2026-09-01 07:36")
      expect(result[:purchased_at_evidence][:candidates].map { |entry| entry[:role] }).to eq(%w[service_start settlement])
    end
  end

  it "壊れたspan・polygon・未知index typeで一意性を主張しない" do
    lines = [ "精算時刻", "2026/09/01 07:36" ]
    bad_span = layout(lines)
    bad_span["pages"].first["lines"].last["spans"].first["offset"] = -1
    bad_polygon = layout(lines)
    bad_polygon["pages"].first["lines"].last["polygon"] = [ 0, 1 ]
    unknown_index = layout(lines).merge("stringIndexType" => "unknown")

    [ bad_span, bad_polygon, unknown_index ].each do |response|
      result = described_class.extract(fields: {}, lines:, profile:, analyze_result: response)

      aggregate_failures do
        expect(result[:purchased_at_text]).to be_nil
        expect(result[:purchased_at_evidence][:complete]).to be(false)
      end
    end
  end

  it "日跨ぎでは精算側の日付を使い、入庫日へ精算時刻を付け足さない" do
    aggregate_failures do
      expect(extract(lines: [ "入庫 2026/09/01 23:50", "精算 2026/09/02 00:10" ])).to eq("2026-09-02 00:10")
      expect(extract(lines: [ "入庫 2026/09/01 23:50", "精算 00:10" ])).to eq("00:10")
    end
  end

  it "精算を通常発行・出庫より優先し、最新日時だけで選ばない" do
    aggregate_failures do
      expect(extract(lines: [ "精算 2026/09/01 07:36", "発行 2026/09/01 07:37", "出庫 2026/09/01 07:40" ])).to eq("2026-09-01 07:36")
      expect(extract(lines: [ "領収証発行 2026/09/01 07:36" ])).to eq("2026-09-01 07:36")
    end
  end

  it "正常な営業時間rangeがあるだけでは一意の購入日時を不完全にしない" do
    result = described_class.extract(fields: {}, lines: [ "営業時間 10:00〜21:00", "2026/09/01 07:36" ], profile:)

    aggregate_failures do
      expect(result[:purchased_at_text]).to eq("2026-09-01 07:36")
      expect(result[:purchased_at_evidence][:complete]).to be(true)
      expect(result[:purchased_at_evidence][:candidates].first[:role]).to eq("reference")
    end
  end

  it "index type欠損時はoffsetを保存せず同一行の日時文法を利用する" do
    lines = [ "購入 2026/09/01 07:36" ]
    response = layout(lines).except("stringIndexType")
    result = described_class.extract(fields: {}, lines:, profile:, analyze_result: response)

    aggregate_failures do
      expect(result[:purchased_at_text]).to eq("2026-09-01 07:36")
      expect(result[:purchased_at_evidence][:candidates].first).not_to have_key(:span)
    end
  end

  it "同じ印字rowのsplit date field spanを結合し別columnのイベントへ流用しない" do
    lines = [ "2026/", "9/01(日)", "7:36" ]
    response = layout(lines, positions: [ [ 0, 0, 5 ], [ 6, 0, 7 ], [ 15, 0, 4 ] ])
    fields = {
      "TransactionDate" => { "valueDate" => "2026-09-01", "spans" => [ { "offset" => 0, "length" => 11 } ] },
      "TransactionTime" => { "valueTime" => "07:36:00", "spans" => response["pages"].first["lines"].last["spans"] }
    }
    result = described_class.extract(fields:, lines:, profile:, analyze_result: response)

    expect(result[:purchased_at_text]).to eq("2026-09-01 07:36:00")

    response["pages"].first["lines"].last["polygon"] = [ 0, 20, 4, 20, 4, 21, 0, 21 ]
    result = described_class.extract(fields:, lines:, profile:, analyze_result: response)

    expect(result[:purchased_at_text]).to be_nil
  end

  it "日時fieldの型違いでraiseせず日時だけを不成立にする" do
    [
      { "TransactionDate" => "malformed", "TransactionTime" => { "valueTime" => "07:36" } },
      { "TransactionDate" => { "valueDate" => "2026-09-01" }, "TransactionTime" => [ "07:36" ] }
    ].each do |fields|
      result = described_class.extract(fields:, lines: [], profile:)

      aggregate_failures do
        expect(result[:purchased_at_text]).to be_nil
        expect(result[:purchased_at_evidence][:invalid]).to be(true)
      end
    end
  end

  it "長すぎるclock tokenを途中まで有効な時刻として採用しない" do
    result = described_class.extract(fields: {}, lines: [ "購入 2026/09/01 12:34:567" ], profile:)

    aggregate_failures do
      expect(result[:purchased_at_text]).to be_nil
      expect(result[:purchased_at_evidence][:complete]).to be(false)
      expect(result[:purchased_at_evidence][:candidates]).not_to include(a_hash_including(time: "12:34"))
    end
  end

  it "日本語表記の秒を捨てずに構造化Timeと同じ精度で保持する" do
    result = described_class.extract(
      fields: {
        "TransactionDate" => { "valueDate" => "2026-09-01" },
        "TransactionTime" => { "valueTime" => "18:42:31" }
      },
      lines: [ "精算 2026年9月1日 18時42分31秒" ], profile:
    )

    aggregate_failures do
      expect(result[:purchased_at_text]).to eq("2026-09-01 18:42:31")
      expect(result.dig(:purchased_at_evidence, :candidates, 0, :time)).to eq("18:42:31")
    end
  end

  it "比率や非日時identifierのcolonを購入日時の競合にしない" do
    result = described_class.extract(fields: {}, lines: [ "比率 2:1", "識別No.03:1234", "購入 2026/09/01 07:36" ], profile:)

    aggregate_failures do
      expect(result[:purchased_at_text]).to eq("2026-09-01 07:36")
      expect(result[:purchased_at_evidence][:complete]).to be(true)
    end
  end
end
