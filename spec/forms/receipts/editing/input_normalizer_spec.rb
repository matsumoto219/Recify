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
            "original_line_total" => "181",
            "line_total" => "999"
          }
        }
      }
    )

    expect(explicit.dig("receipt_items_attributes", "0")).to include(
      "pricing_source_kind" => "explicit_line_total",
      "original_line_total" => 181,
      "line_total" => 181
    )
  end

  it "explicitの可視original line totalを唯一の送信authorityとしてhidden line totalを置き換える" do
    normalized = described_class.call(
      receipt: receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => {
            "pricing_source_kind" => "explicit_line_total",
            "original_line_total" => "0",
            "line_total" => "999"
          },
          "1" => {
            "pricing_source_kind" => "explicit_line_total",
            "original_line_total" => "200"
          }
        }
      }
    ).fetch("receipt_items_attributes")

    aggregate_failures do
      expect(normalized["0"]).to include("original_line_total" => 0, "line_total" => 0)
      expect(normalized["1"]).to include("original_line_total" => 200, "line_total" => 200)
    end
  end

  it "original未記録でpositive discountが残るexplicit rowのfull-form blank authorityを拒否する" do
    persisted_receipt = create(:receipt)
    item = persisted_receipt.receipt_items.create!(
      confirmed_name: "authority不明商品",
      pricing_source_kind: "explicit_line_total",
      quantity: BigDecimal("1"),
      quantity_unit_code: "each",
      original_line_total: nil,
      discount_rate: BigDecimal("0.1"),
      discount_amount: 18,
      line_total: 180
    )

    expect do
      described_class.call(
        receipt: persisted_receipt,
        attributes: {
          "receipt_items_attributes" => {
            "0" => {
              "id" => item.id.to_s,
              "pricing_source_kind" => "explicit_line_total",
              "original_line_total" => "",
              "line_total" => "180",
              "discount_rate" => "10"
            }
          }
        }
      )
    end.to raise_error(Receipts::Editing::InvalidItemSourceError)
  end

  it "original未記録explicit rowのzero-only discountは保存済みline totalへfallbackする" do
    persisted_receipt = create(:receipt)
    item = persisted_receipt.receipt_items.create!(
      confirmed_name: "0割引商品",
      pricing_source_kind: "explicit_line_total",
      quantity: BigDecimal("1"),
      quantity_unit_code: "each",
      original_line_total: nil,
      discount_rate: BigDecimal("0"),
      discount_amount: 0,
      line_total: 180
    )

    normalized = described_class.call(
      receipt: persisted_receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => {
            "id" => item.id.to_s,
            "pricing_source_kind" => "explicit_line_total",
            "original_line_total" => "",
            "line_total" => "999",
            "discount_rate" => "0"
          }
        }
      }
    ).dig("receipt_items_attributes", "0")

    expect(normalized).to include(
      "original_line_total" => nil,
      "line_total" => 180,
      "discount_rate" => BigDecimal("0")
    )
  end

  it "original未記録positive-discount explicit rowのquantity変更はamount authority変更にしない" do
    persisted_receipt = create(:receipt)
    item = persisted_receipt.receipt_items.create!(
      confirmed_name: "authority不明商品",
      pricing_source_kind: "explicit_line_total",
      quantity: BigDecimal("1"),
      quantity_unit_code: "each",
      original_line_total: nil,
      discount_rate: BigDecimal("0.1"),
      discount_amount: 18,
      line_total: 180
    )

    normalized = described_class.call(
      receipt: persisted_receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => {
            "id" => item.id.to_s,
            "quantity" => "2"
          }
        }
      }
    ).dig("receipt_items_attributes", "0")

    expect(normalized).to include("quantity" => BigDecimal("2"))
    expect(normalized).not_to have_key("line_total")
  end

  it "original未記録explicit rowのdiscount source実変更を拒否し、同値echoは許可する" do
    persisted_receipt = create(:receipt)
    item = persisted_receipt.receipt_items.create!(
      confirmed_name: "authority不明商品",
      pricing_source_kind: "explicit_line_total",
      quantity: BigDecimal("1"),
      quantity_unit_code: "each",
      original_line_total: nil,
      discount_rate: BigDecimal("0.1"),
      discount_amount: 18,
      line_total: 180
    )

    expect do
      described_class.call(
        receipt: persisted_receipt,
        attributes: {
          "receipt_items_attributes" => {
            "0" => {
              "id" => item.id.to_s,
              "discount_rate" => "20"
            }
          }
        }
      )
    end.to raise_error(Receipts::Editing::InvalidItemSourceError)

    normalized = described_class.call(
      receipt: persisted_receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => {
            "id" => item.id.to_s,
            "discount_rate" => "10"
          }
        }
      }
    ).dig("receipt_items_attributes", "0")

    expect(normalized).to include("discount_rate" => BigDecimal("0.1"))
  end

  it "新規explicit rowのblank authorityでhidden line totalを破棄する" do
    normalized = described_class.call(
      receipt: receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => {
            "confirmed_name" => "authority未入力商品",
            "pricing_source_kind" => "explicit_line_total",
            "original_line_total" => "",
            "line_total" => "999"
          }
        }
      }
    ).dig("receipt_items_attributes", "0")

    expect(normalized).to include("original_line_total" => nil, "line_total" => nil)
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
      discount_rate: nil,
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
              "original_line_total" => "200",
              "line_total" => "999"
            }
          }
        }
      )
    end.to raise_error(Receipts::Editing::InvalidItemSourceError)
  end

  it "formulaからexplicitへの明示切替でだけdiscount source解除intentを受理する" do
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
      discount_rate: nil,
      line_total: 162
    )

    normalized = described_class.call(
      receipt: persisted_receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => {
            "id" => reference_item.id.to_s,
            "pricing_source_kind" => "explicit_line_total",
            "original_line_total" => "200",
            "line_total" => "999",
            "discount_rate" => "",
            "clear_item_discount_before_explicit" => "1"
          }
        }
      }
    ).dig("receipt_items_attributes", "0")

    expect(normalized).to include(
      "pricing_source_kind" => "explicit_line_total",
      "original_line_total" => 200,
      "line_total" => 200,
      "discount_rate" => nil,
      "discount_amount" => nil
    )
    expect(normalized).not_to have_key("clear_item_discount_before_explicit")
  end

  it "新規rowの未保存formula draftからexplicitへの切替intentを受理する" do
    normalized = described_class.call(
      receipt: receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => {
            "pricing_source_kind" => "explicit_line_total",
            "original_line_total" => "200",
            "discount_rate" => "",
            "clear_item_discount_before_explicit" => "1"
          }
        }
      }
    ).dig("receipt_items_attributes", "0")

    expect(normalized).to include(
      "pricing_source_kind" => "explicit_line_total",
      "original_line_total" => 200,
      "line_total" => 200,
      "discount_rate" => nil,
      "discount_amount" => nil
    )
  end

  it "保存済みformula rowの未保存discount draftを明示intentで破棄する" do
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
      discount_amount: nil,
      discount_rate: nil,
      line_total: 180
    )

    normalized = described_class.call(
      receipt: persisted_receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => {
            "id" => reference_item.id.to_s,
            "pricing_source_kind" => "explicit_line_total",
            "original_line_total" => "200",
            "discount_rate" => "",
            "clear_item_discount_before_explicit" => "1"
          }
        }
      }
    ).dig("receipt_items_attributes", "0")

    expect(normalized).to include(
      "pricing_source_kind" => "explicit_line_total",
      "original_line_total" => 200,
      "line_total" => 200,
      "discount_rate" => nil,
      "discount_amount" => nil
    )
  end

  it "新規explicit rowのintentなしdiscountを割引前sourceとして維持する" do
    normalized = described_class.call(
      receipt: receipt,
      attributes: {
        "receipt_items_attributes" => {
          "0" => {
            "pricing_source_kind" => "explicit_line_total",
            "original_line_total" => "200",
            "line_total" => "200",
            "discount_rate" => "10"
          }
        }
      }
    ).dig("receipt_items_attributes", "0")

    expect(normalized).to include(
      "pricing_source_kind" => "explicit_line_total",
      "original_line_total" => 200,
      "line_total" => 200,
      "discount_rate" => BigDecimal("0.1")
    )
    expect(normalized).not_to have_key("discount_amount")
  end

  it "formula割引解除の確認後に明示金額へ入力し直したdiscountを新sourceとして維持する" do
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
      discount_rate: nil,
      line_total: 162
    )

    { "10" => BigDecimal("0.1"), "0" => BigDecimal("0") }.each do |submitted_rate, expected_rate|
      normalized = described_class.call(
        receipt: persisted_receipt,
        attributes: {
          "receipt_items_attributes" => {
            "0" => {
              "id" => reference_item.id.to_s,
              "pricing_source_kind" => "explicit_line_total",
              "original_line_total" => "200",
              "line_total" => "999",
              "discount_rate" => submitted_rate,
              "clear_item_discount_before_explicit" => "1"
            }
          }
        }
      ).dig("receipt_items_attributes", "0")

      aggregate_failures submitted_rate do
        expect(normalized).to include(
          "pricing_source_kind" => "explicit_line_total",
          "original_line_total" => 200,
          "line_total" => 200,
          "discount_rate" => expected_rate,
          "discount_amount" => nil
        )
        expect(normalized).not_to have_key("clear_item_discount_before_explicit")
      end
    end
  end

  it "保存済みdiscountは0を含むnon-nil値をsourceと判定し、nilだけを未記録と判定する" do
    persisted_receipt = create(:receipt)
    absent_discount_values = [ [ nil, nil ] ]
    present_discount_values = [
      [ BigDecimal("0"), nil ],
      [ nil, 0 ],
      [ BigDecimal("0"), 0 ],
      [ BigDecimal("0.1"), nil ],
      [ nil, 18 ]
    ]

    absent_discount_values.each_with_index do |(discount_rate, discount_amount), index|
      item = persisted_receipt.receipt_items.create!(
        confirmed_name: "解除不要#{index}",
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: BigDecimal("120"),
        reference_quantity: BigDecimal("500"),
        reference_quantity_unit_code: "milliliter",
        reference_price_tax_inclusion: "gross",
        quantity: BigDecimal("750"),
        quantity_unit_code: "milliliter",
        original_line_total: 180,
        discount_rate: discount_rate,
        discount_amount: discount_amount,
        line_total: 180
      )

      normalized = described_class.call(
        receipt: persisted_receipt,
        attributes: {
          "receipt_items_attributes" => {
            "0" => {
              "id" => item.id.to_s,
              "pricing_source_kind" => "explicit_line_total",
              "original_line_total" => "200"
            }
          }
        }
      )

      expect(normalized.dig("receipt_items_attributes", "0", "line_total")).to eq(200)
    end

    present_discount_values.each_with_index do |(discount_rate, discount_amount), index|
      item = persisted_receipt.receipt_items.create!(
        confirmed_name: "解除必要#{index}",
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: BigDecimal("120"),
        reference_quantity: BigDecimal("500"),
        reference_quantity_unit_code: "milliliter",
        reference_price_tax_inclusion: "gross",
        quantity: BigDecimal("750"),
        quantity_unit_code: "milliliter",
        original_line_total: 180,
        discount_rate: discount_rate,
        discount_amount: discount_amount,
        line_total: discount_rate.to_d.positive? || discount_amount.to_i.positive? ? 162 : 180
      )

      expect do
        described_class.call(
          receipt: persisted_receipt,
          attributes: {
            "receipt_items_attributes" => {
              "0" => {
                "id" => item.id.to_s,
                "pricing_source_kind" => "explicit_line_total",
                "original_line_total" => "200"
              }
            }
          }
        )
      end.to raise_error(Receipts::Editing::InvalidItemSourceError)
    end
  end

  it "discount source解除intentをformulaからexplicitへの完全な切替以外で受理しない" do
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

    invalid_inputs = [
      {
        "id" => reference_item.id.to_s,
        "pricing_source_kind" => "reference_quantity_price",
        "clear_item_discount_before_explicit" => "1"
      },
      {
        "id" => reference_item.id.to_s,
        "pricing_source_kind" => "explicit_line_total",
        "original_line_total" => "200",
        "clear_item_discount_before_explicit" => "true"
      },
      {
        "pricing_source_kind" => "explicit_line_total",
        "original_line_total" => "200",
        "clear_item_discount_before_explicit" => "true"
      },
      {
        "pricing_source_kind" => "explicit_line_total",
        "original_line_total" => "200",
        "discount_rate" => "10",
        "clear_item_discount_before_explicit" => "2"
      }
    ]

    invalid_inputs.each do |item_attributes|
      expect do
        described_class.call(
          receipt: persisted_receipt,
          attributes: { "receipt_items_attributes" => { "0" => item_attributes } }
        )
      end.to raise_error(Receipts::Editing::InvalidItemSourceError), item_attributes.inspect
    end
  end

  it "discount rateのblank送信だけでformulaからexplicitへ切り替えない" do
    persisted_receipt = create(:receipt)
    reference_item = persisted_receipt.receipt_items.create!(
      confirmed_name: "割引率付き基準価格商品",
      pricing_source_kind: "reference_quantity_price",
      reference_price_amount: BigDecimal("120"),
      reference_quantity: BigDecimal("500"),
      reference_quantity_unit_code: "milliliter",
      reference_price_tax_inclusion: "gross",
      quantity: BigDecimal("750"),
      quantity_unit_code: "milliliter",
      original_line_total: 180,
      discount_amount: nil,
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
              "original_line_total" => "200",
              "discount_rate" => ""
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

  it "pricing source kind未記録rowではblank defaultとalias normalizationを維持する" do
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
