require "rails_helper"

RSpec.describe Receipts::Editing::InputNormalizer do
  subject(:normalize) { described_class.call(receipt: receipt, attributes: attributes) }

  let(:receipt) { build(:receipt) }

  context "with measurement pricing source input" do
    let(:attributes) do
      {
        "receipt_items_attributes" => {
          "0" => {
            "pricing_source_kind" => "reference_quantity_price",
            "reference_price_amount" => "１２０．５０００００",
            "reference_quantity" => "５００．０００",
            "reference_quantity_unit_code" => "milliliter",
            "quantity_unit_code" => "liter",
            "quantity_unit_raw" => "",
            "reference_quantity_unit_raw" => "   ",
            "reference_price_tax_inclusion" => "gross"
          }
        }
      }
    end

    it "strictなdecimalへ変換し、blank source metadataをnilへ正規化する" do
      normalized = normalize.dig("receipt_items_attributes", "0")

      expect(normalized).to include(
        "pricing_source_kind" => "reference_quantity_price",
        "reference_price_amount" => BigDecimal("120.5"),
        "reference_quantity" => BigDecimal("500"),
        "reference_quantity_unit_code" => "milliliter",
        "quantity_unit_code" => "liter",
        "quantity_unit_raw" => nil,
        "reference_quantity_unit_raw" => nil,
        "reference_price_tax_inclusion" => "gross"
      )
    end

    it "callerのsource hashを変更しない" do
      snapshot = attributes.deep_dup

      normalize

      expect(attributes).to eq(snapshot)
    end
  end

  it "formula authorityのblank・alias・unknown unitをeachやcanonical codeへ暗黙変換しない" do
    normalized = described_class.call(
      receipt: receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => {
            "pricing_source_kind" => "reference_quantity_price",
            "quantity_unit_code" => "",
            "reference_quantity_unit_code" => ""
          },
          "1" => {
            "pricing_source_kind" => "reference_quantity_price",
            "quantity_unit_code" => "ml",
            "reference_quantity_unit_code" => "ml"
          },
          "2" => {
            "pricing_source_kind" => "count_unit_price",
            "quantity_unit_code" => "個"
          },
          "3" => {
            "pricing_source_kind" => "reference_quantity_price",
            "quantity_unit_code" => "束",
            "reference_quantity_unit_code" => "容量"
          }
        }
      }
    ).fetch("receipt_items_attributes")

    aggregate_failures do
      expect(normalized["0"]).to include(
        "quantity_unit_code" => nil,
        "reference_quantity_unit_code" => nil
      )
      expect(normalized["1"]).to include(
        "quantity_unit_code" => "ml",
        "reference_quantity_unit_code" => "ml"
      )
      expect(normalized.dig("2", "quantity_unit_code")).to eq("個")
      expect(normalized["3"]).to include(
        "quantity_unit_code" => "束",
        "reference_quantity_unit_code" => "容量"
      )
    end
  end

  it "persisted formula rowのpartial入力でも保存済みkindを使ってunit aliasを暗黙変換しない" do
    persisted_receipt = create(:receipt)
    item = persisted_receipt.receipt_items.create!(
      confirmed_name: "基準価格商品",
      pricing_source_kind: "reference_quantity_price",
      reference_price_amount: BigDecimal("140"),
      reference_quantity: BigDecimal("1"),
      reference_quantity_unit_code: "liter",
      reference_price_tax_inclusion: "gross",
      quantity: BigDecimal("8.12"),
      quantity_unit_code: "liter",
      original_line_total: 1_137,
      line_total: 1_137
    )

    normalized = described_class.call(
      receipt: persisted_receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => { "id" => item.id.to_s, "quantity_unit_code" => "ml" }
        }
      }
    )

    expect(normalized.dig("receipt_items_attributes", "0", "quantity_unit_code")).to eq("ml")
  end

  it "source kindの新規指定・切替ではkind別sourceを明示送信させる" do
    persisted_receipt = create(:receipt)
    reference_item = persisted_receipt.receipt_items.create!(
      confirmed_name: "基準価格商品",
      pricing_source_kind: "reference_quantity_price",
      reference_price_amount: BigDecimal("120"),
      reference_quantity: BigDecimal("500"),
      reference_quantity_unit_code: "milliliter",
      reference_price_tax_inclusion: "gross",
      quantity: BigDecimal("750"),
      quantity_unit_code: "milliliter",
      original_line_total: 180,
      line_total: 180
    )

    invalid_transitions = [
      { "id" => reference_item.id.to_s, "pricing_source_kind" => "explicit_line_total" },
      { "id" => reference_item.id.to_s, "pricing_source_kind" => "" }
    ]

    invalid_transitions.each do |item_attributes|
      expect do
        described_class.call(
          receipt: persisted_receipt,
          attributes: { "receipt_items_attributes" => { "0" => item_attributes } }
        )
      end.to raise_error(Receipts::Editing::InvalidItemSourceError), item_attributes.inspect
    end

    explicit = described_class.call(
      receipt: persisted_receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => {
            "id" => reference_item.id.to_s,
            "pricing_source_kind" => "explicit_line_total",
            "line_total" => "181"
          }
        }
      }
    )

    expect(explicit.dig("receipt_items_attributes", "0")).to include(
      "pricing_source_kind" => "explicit_line_total",
      "line_total" => 181
    )
  end

  it "discount sourceが残るformulaからexplicitへの曖昧な切替を拒否する" do
    persisted_receipt = create(:receipt)
    reference_item = persisted_receipt.receipt_items.create!(
      confirmed_name: "割引付き基準価格商品",
      pricing_source_kind: "reference_quantity_price",
      reference_price_amount: BigDecimal("120"),
      reference_quantity: BigDecimal("500"),
      reference_quantity_unit_code: "milliliter",
      reference_price_tax_inclusion: "gross",
      quantity: BigDecimal("750"),
      quantity_unit_code: "milliliter",
      original_line_total: 180,
      discount_amount: 18,
      discount_rate: BigDecimal("0.1"),
      line_total: 162
    )

    expect do
      described_class.call(
        receipt: persisted_receipt,
        attributes: {
          "receipt_items_attributes" => {
            "0" => {
              "id" => reference_item.id.to_s,
              "pricing_source_kind" => "explicit_line_total",
              "line_total" => "200"
            }
          }
        }
      )
    end.to raise_error(Receipts::Editing::InvalidItemSourceError)
  end

  it "保存済みabsolute discountから表示用に導出したrateのechoをsource入力へ昇格させない" do
    persisted_receipt = create(:receipt)
    item = persisted_receipt.receipt_items.create!(
      confirmed_name: "割引額だけを持つ商品",
      pricing_source_kind: "explicit_line_total",
      quantity: BigDecimal("1"),
      quantity_unit_code: "each",
      original_line_total: 100,
      discount_amount: 10,
      discount_rate: nil,
      line_total: 90
    )

    normalized = described_class.call(
      receipt: persisted_receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => {
            "id" => item.id.to_s,
            "discount_rate" => item.discount_rate_percentage_input
          }
        }
      }
    )

    expect(normalized.dig("receipt_items_attributes", "0")).not_to have_key("discount_rate")

    changed = described_class.call(
      receipt: persisted_receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => { "id" => item.id.to_s, "discount_rate" => "20" }
        }
      }
    )

    expect(changed.dig("receipt_items_attributes", "0", "discount_rate")).to eq(BigDecimal("0.2"))
  end

  it "新規itemの明示discount rateを保存済みechoとして扱わない" do
    normalized = described_class.call(
      receipt: receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => { "discount_rate" => "10" }
        }
      }
    )

    expect(normalized.dig("receipt_items_attributes", "0", "discount_rate")).to eq(BigDecimal("0.1"))
  end

  it "manual HTTPからunknown raw unit evidenceを新規作成・変更させない" do
    %w[quantity_unit_raw reference_quantity_unit_raw].each do |field|
      attributes = {
        "receipt_items_attributes" => {
          "0" => {
            "pricing_source_kind" => nil,
            "quantity_unit_code" => "each",
            field => "bundle"
          }
        }
      }

      expect do
        described_class.call(receipt: receipt, attributes: attributes)
      end.to raise_error(Receipts::Editing::InvalidItemSourceError), field
    end

    persisted_receipt = create(:receipt)
    diagnostic_item = persisted_receipt.receipt_items.create!(
      confirmed_name: "未対応単位商品",
      quantity: BigDecimal("1"),
      quantity_unit_code: "each",
      quantity_unit_raw: "bundle",
      reference_price_amount: BigDecimal("100"),
      reference_quantity: BigDecimal("2"),
      reference_quantity_unit_raw: "bundle-size",
      line_total: 100
    )

    expect do
      described_class.call(
        receipt: persisted_receipt,
        attributes: {
          "receipt_items_attributes" => {
            "0" => { "id" => diagnostic_item.id.to_s, "quantity_unit_raw" => "" }
          }
        }
      )
    end.to raise_error(Receipts::Editing::InvalidItemSourceError)
  end

  it "manual HTTPからauthority-free diagnostic reference evidenceを新規作成しない" do
    expect do
      described_class.call(
        receipt: receipt,
        attributes: {
          "receipt_items_attributes" => {
            "0" => {
              "pricing_source_kind" => "",
              "reference_price_amount" => "100",
              "reference_quantity" => "2",
              "reference_quantity_unit_code" => "each"
            }
          }
        }
      )
    end.to raise_error(Receipts::Editing::InvalidItemSourceError)
  end

  it "manual HTTPから保存済みauthority-free diagnostic reference evidenceを消去しない" do
    persisted_receipt = create(:receipt)
    diagnostic_item = persisted_receipt.receipt_items.create!(
      confirmed_name: "診断情報付き商品",
      price: 100,
      quantity: BigDecimal("2"),
      quantity_unit_code: "each",
      reference_price_amount: BigDecimal("100"),
      reference_quantity: BigDecimal("2"),
      reference_quantity_unit_code: "each",
      reference_price_tax_inclusion: "gross",
      line_total: 100
    )

    expect do
      described_class.call(
        receipt: persisted_receipt,
        attributes: {
          "receipt_items_attributes" => {
            "0" => {
              "id" => diagnostic_item.id.to_s,
              "reference_price_amount" => "",
              "reference_quantity" => "",
              "reference_quantity_unit_code" => "",
              "reference_price_tax_inclusion" => ""
            }
          }
        }
      )
    end.to raise_error(Receipts::Editing::InvalidItemSourceError)
  end

  it "保存済みauthority-free diagnosticの金額sourceをkind遷移なしで変更しない" do
    persisted_receipt = create(:receipt)
    diagnostic_item = persisted_receipt.receipt_items.create!(
      confirmed_name: "金額未確定の診断商品",
      price: 100,
      quantity: BigDecimal("2"),
      quantity_unit_code: "each",
      reference_price_amount: BigDecimal("100"),
      reference_quantity: BigDecimal("2"),
      reference_quantity_unit_code: "each",
      reference_price_tax_inclusion: "gross",
      original_line_total: nil,
      line_total: nil
    )

    invalid_changes = [
      { "price" => "101" },
      { "quantity" => "3" },
      { "quantity_unit_code" => "box" },
      { "original_line_total" => "100" },
      { "line_total" => "100" },
      { "discount_rate" => "10" }
    ]

    invalid_changes.each do |change|
      expect do
        described_class.call(
          receipt: persisted_receipt,
          attributes: {
            "receipt_items_attributes" => {
              "0" => { "id" => diagnostic_item.id.to_s }.merge(change)
            }
          }
        )
      end.to raise_error(Receipts::Editing::InvalidItemSourceError), change.inspect
    end

    unchanged = described_class.call(
      receipt: persisted_receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => {
            "id" => diagnostic_item.id.to_s,
            "price" => "100",
            "quantity" => "2.0",
            "quantity_unit_code" => "each",
            "original_line_total" => "",
            "line_total" => ""
          }
        }
      }
    )

    expect(unchanged.dig("receipt_items_attributes", "0")).to include(
      "price" => 100,
      "quantity" => BigDecimal("2"),
      "quantity_unit_code" => "each",
      "original_line_total" => nil,
      "line_total" => nil
    )
  end

  it "legacy rowでは現行のblank defaultとalias normalizationを維持する" do
    normalized = described_class.call(
      receipt: receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => { "quantity_unit_code" => "" },
          "1" => { "quantity_unit_code" => "ml" }
        }
      }
    ).fetch("receipt_items_attributes")

    aggregate_failures do
      expect(normalized.dig("0", "quantity_unit_code")).to eq(ReceiptQuantityUnit.default_code)
      expect(normalized.dig("1", "quantity_unit_code")).to eq("milliliter")
    end
  end

  it "不正なreference decimalを0やnilへ変換せず拒否する" do
    source = {
      "receipt_items_attributes" => {
        "0" => {
          "pricing_source_kind" => "reference_quantity_price",
          "reference_price_amount" => "120abc",
          "reference_quantity" => "500"
        }
      }
    }
    snapshot = source.deep_dup

    expect do
      described_class.call(receipt: receipt, attributes: source)
    end.to raise_error(Receipts::NumericInput::InvalidValue)

    expect(source).to eq(snapshot)
  end
end
