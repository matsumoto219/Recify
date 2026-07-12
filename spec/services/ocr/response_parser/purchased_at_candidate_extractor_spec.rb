require "rails_helper"

RSpec.describe Ocr::ResponseParser::PurchasedAtCandidateExtractor do
  let(:profile) { ReceiptAnalysisProfiles.default }

  def extract(fields: {}, lines: [], profile: self.profile)
    described_class.call(fields:, lines:, profile:)
  end

  it "structured日時をline fallbackより優先し、値を検証せずslashだけ正規化する" do
    fields = {
      "TransactionDate" => { "valueDate" => "2026/99/40" },
      "TransactionTime" => { "valueTime" => "25:99:00" }
    }

    expect(extract(fields:, lines: [ "2026/05/20 18:42" ])).to eq("2026-99-40 25:99:00")
  end

  it "structured日時のcompact joinへstripやpresence filterを加えない" do
    fields = {
      "TransactionDate" => { "valueDate" => "" },
      "TransactionTime" => { "valueTime" => "18:42" }
    }

    expect(extract(fields:)).to eq(" 18:42")
  end

  it "最初の日付行を採用し、同一行の時刻と日付内空白を優先して正規化する" do
    lines = [
      "2026 / 05 / 20 9 ： 05",
      "2026/05/21 10:15"
    ]

    expect(extract(lines:)).to eq("2026-05-20 9:05")
  end

  it "周辺時刻を+1、-1、+2、-2の順で選ぶ" do
    cases = [
      [ [ "08:00", "09:00", "2026/05/20", "10:00", "11:00" ], "10:00" ],
      [ [ "08:00", "09:00", "2026/05/20", "invalid", "11:00" ], "09:00" ],
      [ [ "08:00", "invalid", "2026/05/20", "invalid", "11:00" ], "11:00" ],
      [ [ "08:00", "invalid", "2026/05/20", "invalid", "invalid" ], "08:00" ]
    ]

    cases.each do |lines, expected_time|
      expect(extract(lines:)).to eq("2026-05-20 #{expected_time}")
    end
  end

  it "日付があれば遠方時刻を探索せず、日付がなければ最初の有効時刻を返す" do
    aggregate_failures do
      expect(extract(lines: [ "2026/05/20", "商品", "小計", "合計", "18:42" ])).to eq("2026-05-20")
      expect(extract(lines: [ "24:00", "12:60", "9:05", "10:15" ])).to eq("9:05")
    end
  end

  it "profileから注入された日付patternだけを使用する" do
    custom_profile = double(
      "receipt analysis profile",
      ocr_purchased_at_date_patterns: [ /custom\s*\d{4}/ ]
    )

    expect(extract(lines: [ "2026/05/20", "custom 2026" ], profile: custom_profile)).to eq("custom2026")
  end

  it "calendarとして不正でもprofile patternに一致する日付はそのまま返す" do
    expect(extract(lines: [ "2026/99/99" ])).to eq("2026-99-99")
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

  it "malformed fieldsとprofile contract errorを握り潰さない" do
    aggregate_failures do
      expect { extract(fields: "invalid") }.to raise_error(NoMethodError)
      expect { extract(lines: [ "2026/05/20" ], profile: Object.new) }.to raise_error(NoMethodError)
    end
  end
end
