# frozen_string_literal: true

require_relative "../../../tools/generated_receipts"

RSpec.describe GeneratedReceipts::TextRenderer do
  def load_case(name)
    path = [
      GeneratedReceipts::CASES_DIR,
      GeneratedReceipts::MEASUREMENT_CASES_DIR,
      GeneratedReceipts::CALCULATION_MODE_CASES_DIR
    ].map { |directory| File.join(directory, "#{name}.json") }
      .find { |candidate| File.file?(candidate) }

    GeneratedReceipts::Validator.load_file(path)
  end

  it "renders text that matches generated fixture text files" do
    aggregate_failures do
      expect(GeneratedReceipts.legacy_case_paths.size).to eq(112)
      expect(GeneratedReceipts.measurement_case_paths.size).to eq(10)
      expect(GeneratedReceipts.calculation_mode_case_paths.size).to eq(29)
      expect(GeneratedReceipts.case_paths.size).to eq(151)
    end

    GeneratedReceipts.case_paths.each do |path|
      case_data = GeneratedReceipts::Validator.load_file(path)
      text_path = File.join(GeneratedReceipts::TEXT_DIR, "#{case_data.fetch('case_id')}.txt")

      expect(File.read(text_path)).to eq(described_class.call(case_data))
    end
  end

  it "renders mixed calculation-mode source lines in item-index order" do
    text = described_class.call(load_case("g143_calc_mixed_three_modes"))

    aggregate_failures do
      expect(text).to include("@150円 × 2個")
      expect(text).to include("税込 398円/100g")
      expect(text).to include("サンプル固定C 500円")
      expect(text.index("@150円 × 2個")).to be < text.index("税込 398円/100g")
      expect(text.index("税込 398円/100g")).to be < text.index("サンプル固定C 500円")
    end
  end

  it "renders totals, tax details, adjustments, and payments for a surcharge case" do
    text = described_class.call(load_case("g007_adjustment_delivery_bag_fee"))

    aggregate_failures do
      expect(text).to include("サンプルデリバリー 配送テスト店")
      expect(text).to include("レジ袋代 ¥10")
      expect(text).to include("配送料 ¥550")
      expect(text).to include("合計 ¥1,804")
      expect(text).to include("10%消費税 ¥164")
      expect(text).to include("PayPay支払 ¥1,804")
    end
  end

  it "keeps OCR noise as context without inventing a payment line" do
    text = described_class.call(load_case("g010_ocr_noise_payment_context"))

    aggregate_failures do
      expect(text).to include("sivendidolo ros")
      expect(text).to include("PayPay支払 ¥250")
      expect(text).not_to include("sivendidolo ros ¥5")
    end
  end

  it "can omit the printed subtotal line while keeping tax detail source of truth" do
    text = described_class.call(load_case("g014_normal_missing_subtotal_tax_detail"))

    aggregate_failures do
      expect(text).not_to include("小計 ¥1,000")
      expect(text).to include("10%対象計 ¥1,100")
      expect(text).to include("合計 ¥1,100")
    end
  end

  it "can render an explicit payment block heading for split payments" do
    text = described_class.call(load_case("g030_payment_three_way_split"))

    aggregate_failures do
      expect(text).to include("お支払い方法")
      expect(text).to include("サンプル商品券 ¥1,000")
      expect(text).to include("クレジット ¥500")
      expect(text).to include("現金 ¥1,800")
    end
  end

  it "uses custom lines when a case needs non-standard source text" do
    text = described_class.call(load_case("g081_non_receipt_memo"))

    aggregate_failures do
      expect(text).to include("買い物メモ")
      expect(text).not_to include("領収書")
      expect(text).not_to include("合計")
    end
  end

  it "renders measurement item source lines without deriving them from expected amounts" do
    case_data = load_case("g001_normal_included_10_cash")
    case_data["source"] = {
      "items" => [
        {
          "item_index" => 2,
          "printed_lines" => [ "税込 ¥120/500ml", "1500ml", "¥360" ]
        },
        {
          "item_index" => 0,
          "printed_lines" => [ "税込 ¥1,480/100g", "342g", "¥5,061" ]
        }
      ]
    }

    text = described_class.call(case_data)

    aggregate_failures do
      expect(text).to include("税込 ¥1,480/100g\n342g\n¥5,061\n税込 ¥120/500ml\n1500ml\n¥360")
      expect(text).not_to include("サンプル弁当A ¥550")
      expect(text).not_to include("サンプル雑貨C ¥110")
      expect(text).to include("合計 ¥880")
    end
  end

  it "keeps legacy item rendering unchanged when measurement source is absent" do
    case_data = load_case("g001_normal_included_10_cash")

    expect(described_class.call(case_data)).to include(
      "サンプル弁当A ¥550\nサンプル飲料B ¥220\nサンプル雑貨C ¥110"
    )
  end
end
