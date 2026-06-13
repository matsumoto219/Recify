# frozen_string_literal: true

require_relative "../../../tools/generated_receipts"

RSpec.describe GeneratedReceipts::TextRenderer do
  def load_case(name)
    GeneratedReceipts::Validator.load_file(File.join(GeneratedReceipts::CASES_DIR, "#{name}.json"))
  end

  it "renders text that matches generated fixture text files" do
    Dir[File.join(GeneratedReceipts::CASES_DIR, "*.json")].sort.each do |path|
      case_data = GeneratedReceipts::Validator.load_file(path)
      text_path = File.join(GeneratedReceipts::TEXT_DIR, "#{case_data.fetch('case_id')}.txt")

      expect(File.read(text_path)).to eq(described_class.call(case_data))
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
end
