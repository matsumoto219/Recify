require "rails_helper"
require "timeout"

RSpec.describe "Receipts input forms" do
  def normalize_with(form_class, receipt:, attributes:)
    form_class.call(receipt: receipt, attributes: attributes)
  end

  shared_examples "receipt input normalization" do |form_class|
    it "購入日時とreceipt/item/adjustment/paymentの数値を正規化する" do
      receipt = build(:receipt)
      attributes = {
        "purchased_on" => "2026-07-12",
        "purchased_time" => "09:30",
        "total_amount" => "１，２００",
        "tax_rate" => "１０．５",
        "receipt_items_attributes" => {
          "0" => {
            "price" => "1,000",
            "original_line_total" => "１，０００",
            "line_total" => "９００",
            "quantity" => "0,300",
            "tax_rate" => "８",
            "discount_rate" => "5.5",
            "quantity_unit_code" => "kilogram"
          }
        },
        "receipt_adjustments_attributes" => {
          "0" => { "kind" => "coupon", "amount" => "１００", "tax_rate" => "１０", "sign" => "surcharge" }
        },
        "receipt_payments_attributes" => {
          "0" => { "method" => "cash", "amount" => "1,100" }
        }
      }

      normalized = normalize_with(form_class, receipt: receipt, attributes: attributes)

      aggregate_failures do
        expect(normalized).not_to have_key("purchased_on")
        expect(normalized).not_to have_key("purchased_time")
        expect(normalized["purchased_at"]).to eq(Time.zone.parse("2026-07-12 09:30"))
        expect(normalized["total_amount"]).to eq(1200)
        expect(normalized["tax_rate"]).to eq(BigDecimal("10.5"))
        expect(normalized.dig("receipt_items_attributes", "0")).to include(
          "price" => 1000,
          "original_line_total" => 1000,
          "line_total" => 900,
          "quantity" => BigDecimal("0.3"),
          "tax_rate" => BigDecimal("0.08"),
          "discount_rate" => BigDecimal("0.055"),
          "quantity_unit_code" => "kilogram"
        )
        expect(normalized.dig("receipt_adjustments_attributes", "0")).to include(
          "amount" => 100,
          "tax_rate" => BigDecimal("0.1"),
          "sign" => "discount",
          "source" => "manual",
          "needs_review" => false,
          "review_reasons" => []
        )
        expect(normalized.dig("receipt_payments_attributes", "0", "amount")).to eq(1100)
      end
    end


    it "item割引率をbounded percentageからratioへ正規化する" do
      receipt = build(:receipt)
      attributes = {
        "receipt_items_attributes" => {
          "0" => { "discount_rate" => "0.5" },
          "1" => { "discount_rate" => "1" },
          "2" => { "discount_rate" => "1.1" },
          "3" => { "discount_rate" => "5.5" },
          "4" => { "discount_rate" => "100" }
        }
      }

      normalized = normalize_with(form_class, receipt: receipt, attributes: attributes)

      expect(normalized["receipt_items_attributes"].values.pluck("discount_rate")).to eq(
        [
          BigDecimal("0.005"),
          BigDecimal("0.01"),
          BigDecimal("0.011"),
          BigDecimal("0.055"),
          BigDecimal("1")
        ]
      )
    end

    it "100%を超えるitem割引率を拒否する" do
      receipt = build(:receipt)

      expect {
        normalize_with(
          form_class,
          receipt: receipt,
          attributes: { "receipt_items_attributes" => { "0" => { "discount_rate" => "100.1" } } }
        )
      }.to raise_error(Receipts::NumericInput::InvalidValue)
    end

    it "永続tax rateのscaleを超えるreceipt入力を拒否する" do
      expect {
        normalize_with(
          form_class,
          receipt: build(:receipt),
          attributes: { "tax_rate" => "0.10555" }
        )
      }.to raise_error(Receipts::NumericInput::InvalidValue)
    end

    it "永続tax rateのscaleを超えるitem百分率入力を拒否する" do
      expect {
        normalize_with(
          form_class,
          receipt: build(:receipt),
          attributes: { "receipt_items_attributes" => { "0" => { "tax_rate" => "10.555" } } }
        )
      }.to raise_error(Receipts::NumericInput::InvalidValue)
    end

    it "永続discount rateのscaleを超えるitem百分率入力を拒否する" do
      expect {
        normalize_with(
          form_class,
          receipt: build(:receipt),
          attributes: { "receipt_items_attributes" => { "0" => { "discount_rate" => "10.55" } } }
        )
      }.to raise_error(Receipts::NumericInput::InvalidValue)
    end

    it "永続tax rateのscaleを超えるadjustment百分率入力を拒否する" do
      expect {
        normalize_with(
          form_class,
          receipt: build(:receipt),
          attributes: { "receipt_adjustments_attributes" => { "0" => { "tax_rate" => "10.555" } } }
        )
      }.to raise_error(Receipts::NumericInput::InvalidValue)
    end

    it "blank数量単位をdefaultへ補い、未知の入力値はvalidation用に保持する" do
      receipt = build(:receipt)
      attributes = {
        "receipt_items_attributes" => {
          "0" => { "quantity_unit_code" => "" },
          "1" => { "quantity_unit_code" => "束" }
        }
      }

      normalized = normalize_with(form_class, receipt: receipt, attributes: attributes)

      expect(normalized["receipt_items_attributes"]).to eq(
        "0" => { "quantity_unit_code" => ReceiptQuantityUnit.default_code },
        "1" => { "quantity_unit_code" => "束" }
      )
    end

    it "不正数値を拒否し、callerの入力Hashを変更しない" do
      receipt = build(:receipt)
      attributes = { "total_amount" => "12abc" }

      expect {
        normalize_with(form_class, receipt: receipt, attributes: attributes)
      }.to raise_error(Receipts::NumericInput::InvalidValue)

      expect(attributes).to eq("total_amount" => "12abc")
    end

    it "不正なitem original_line_totalを拒否する" do
      receipt = build(:receipt)

      expect {
        normalize_with(
          form_class,
          receipt: receipt,
          attributes: {
            "receipt_items_attributes" => {
              "0" => { "original_line_total" => "12abc" }
            }
          }
        )
      }.to raise_error(Receipts::NumericInput::InvalidValue)
    end
  end

  include_examples "receipt input normalization", Receipts::ManualEntryForm
  include_examples "receipt input normalization", Receipts::EditForm

  it "手動入力の巨大な基準価格をInputNormalizer境界で短時間にtyped rejectionする" do
    oversized = "9" * 100_000
    attributes = {
      "receipt_items_attributes" => {
        "0" => {
          "pricing_source_kind" => "reference_quantity_price",
          "reference_price_amount" => oversized,
          "reference_quantity" => "1",
          "reference_quantity_unit_code" => "gram",
          "reference_price_tax_inclusion" => "gross",
          "quantity" => "1",
          "quantity_unit_code" => "gram"
        }
      }
    }

    expect {
      Timeout.timeout(1) do
        Receipts::ManualEntryForm.call(receipt: build(:receipt), attributes: attributes)
      end
    }.to raise_error(Receipts::NumericInput::InvalidValue, "Invalid user numeric input")

    expect(attributes.dig("receipt_items_attributes", "0", "reference_price_amount")).to equal(oversized)
  end

  describe Receipts::EditForm do
    it "既存itemのpartial入力で未送信の数量単位を補完しない" do
      receipt = create(:receipt, :completed)
      item = receipt.receipt_items.create!(
        confirmed_name: "旧商品名",
        quantity: BigDecimal("0.5"),
        quantity_unit_code: "kilogram",
        line_total: 100
      )
      attributes = {
        "receipt_items_attributes" => {
          "0" => {
            "id" => item.id.to_s,
            "confirmed_name" => "確認済み商品名"
          }
        }
      }

      normalized = described_class.call(receipt: receipt, attributes: attributes)
      item_attributes = normalized.dig("receipt_items_attributes", "0")

      aggregate_failures do
        expect(item_attributes).to include(
          "id" => item.id.to_s,
          "confirmed_name" => "確認済み商品名"
        )
        expect(item_attributes).not_to have_key("quantity_unit_code")
      end
    end

    it "既存adjustmentのpartial入力で未送信fieldと確認済みmarkerを補完しない" do
      receipt = create(:receipt, :completed)
      adjustment = create(
        :receipt_adjustment,
        receipt: receipt,
        kind: "coupon",
        label: "確認前クーポン",
        amount: 100,
        sign: "discount",
        source: "ai",
        needs_review: true,
        review_reasons: [ "adjustment_uncertain" ]
      )
      attributes = {
        "receipt_adjustments_attributes" => {
          "0" => { "id" => adjustment.id.to_s }
        }
      }

      normalized = described_class.call(receipt: receipt, attributes: attributes)

      expect(normalized.dig("receipt_adjustments_attributes", "0")).to eq(
        "id" => adjustment.id.to_s
      )
    end

    it "未変更の既存adjustmentはsource/review stateを上書きしない" do
      receipt = create(:receipt, :completed)
      adjustment = create(
        :receipt_adjustment,
        receipt: receipt,
        kind: "delivery_fee",
        label: "送料",
        amount: 100,
        sign: "surcharge",
        tax_rate: BigDecimal("0.1"),
        source: "ai",
        needs_review: true,
        review_reasons: [ "adjustment_uncertain" ]
      )
      attributes = {
        "receipt_adjustments_attributes" => {
          "0" => {
            "id" => adjustment.id.to_s,
            "kind" => "delivery_fee",
            "label" => "送料",
            "amount" => "100",
            "sign" => "surcharge",
            "tax_rate" => "10"
          }
        }
      }

      normalized = described_class.call(receipt: receipt, attributes: attributes)
      adjustment_attributes = normalized.dig("receipt_adjustments_attributes", "0")

      aggregate_failures do
        expect(adjustment_attributes).not_to have_key("source")
        expect(adjustment_attributes).not_to have_key("needs_review")
        expect(adjustment_attributes).not_to have_key("review_reasons")
        expect(adjustment.reload).to have_attributes(
          source: "ai",
          needs_review: true,
          review_reasons: [ "adjustment_uncertain" ]
        )
      end
    end

    it "既存adjustmentのnil labelを空白だけで再送信してもreview stateを上書きしない" do
      receipt = create(:receipt, :completed)
      adjustment = create(
        :receipt_adjustment,
        receipt: receipt,
        kind: "delivery_fee",
        label: nil,
        amount: 100,
        sign: "surcharge",
        source: "ai",
        needs_review: true,
        review_reasons: [ "adjustment_uncertain" ]
      )
      attributes = {
        "receipt_adjustments_attributes" => {
          "0" => {
            "id" => adjustment.id.to_s,
            "kind" => "delivery_fee",
            "label" => "   ",
            "amount" => "100",
            "sign" => "surcharge",
            "tax_rate" => ""
          }
        }
      }

      normalized = described_class.call(receipt: receipt, attributes: attributes)
      adjustment_attributes = normalized.dig("receipt_adjustments_attributes", "0")

      aggregate_failures do
        expect(adjustment_attributes).not_to have_key("source")
        expect(adjustment_attributes).not_to have_key("needs_review")
        expect(adjustment_attributes).not_to have_key("review_reasons")
      end
    end

    it "編集された既存adjustmentだけをmanual confirmed stateへ正規化する" do
      receipt = create(:receipt, :completed)
      adjustment = create(
        :receipt_adjustment,
        receipt: receipt,
        kind: "other",
        label: "旧ラベル",
        amount: 100,
        sign: "discount",
        source: "ai",
        needs_review: true,
        review_reasons: [ "adjustment_uncertain" ]
      )
      attributes = {
        "receipt_adjustments_attributes" => {
          "0" => {
            "id" => adjustment.id.to_s,
            "kind" => "other",
            "label" => "新ラベル",
            "amount" => "100",
            "sign" => "discount"
          }
        }
      }

      normalized = described_class.call(receipt: receipt, attributes: attributes)

      aggregate_failures do
        expect(normalized.dig("receipt_adjustments_attributes", "0")).to include(
          "sign" => "discount",
          "source" => "manual",
          "needs_review" => false,
          "review_reasons" => []
        )
        expect(adjustment.reload).to have_attributes(
          label: "旧ラベル",
          source: "ai",
          needs_review: true,
          review_reasons: [ "adjustment_uncertain" ]
        )
      end
    end
  end
end
