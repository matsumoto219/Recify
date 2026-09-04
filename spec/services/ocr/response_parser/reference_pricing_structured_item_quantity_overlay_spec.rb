require "rails_helper"
require Rails.root.join("spec/support/ocr/structured_items_gross_fixture")

RSpec.describe Ocr::ResponseParser::ReferencePricingStructuredItemQuantityOverlay do
  include StructuredItemsGrossFixture

  def parenthetical_response
    item_specs = [
      {
        description: "匿名量売品甲",
        price_text: "240円",
        price_amount: 240,
        quantity_text: "2.5L(個)",
        quantity_amount: 2.5,
        quantity_unit: "個",
        total_text: "600円",
        total_amount: 600
      },
      {
        description: "匿名量売品乙",
        price_text: "300円",
        price_amount: 300,
        quantity_text: "2L(個)",
        quantity_amount: 2,
        quantity_unit: "個",
        total_text: "600円",
        total_amount: 600
      },
      {
        description: "匿名固定額品",
        price_text: "50円",
        price_amount: 50,
        quantity_text: "1個",
        quantity_amount: 1,
        quantity_unit: "個",
        total_text: "50円",
        total_amount: 50
      }
    ]
    response = build_structured_items_gross_response(item_specs:, total_amount: 1_250)
    analyze_result = response.fetch("analyzeResult")
    items = analyze_result.dig("documents", 0, "fields", "Items", "valueArray")
    lines = analyze_result.dig("pages", 0, "lines")

    [ [ 0, "2.5L(", 2.5 ], [ 1, "2L(", 2 ] ].each do |item_index, quantity_content, value|
      line = lines.fetch((item_index * 4) + 2)
      line_offset = line.dig("spans", 0, "offset")
      quantity_length = structured_items_gross_provider_length(quantity_content, "textElements")
      fields = items.fetch(item_index).fetch("valueObject")
      fields["Quantity"].merge!(
        "content" => quantity_content,
        "valueNumber" => value,
        "spans" => [ { "offset" => line_offset, "length" => quantity_length } ]
      )
      fields["QuantityUnit"].merge!(
        "content" => "個",
        "valueString" => "個",
        "spans" => [ { "offset" => line_offset + quantity_length, "length" => 1 } ]
      )
    end

    response
  end

  def parsed_result(response = parenthetical_response)
    Ocr::ResponseParser.new(response:, provider: :fixture).call
  end

  def extract_overlays(response:, references:, carriers:, excluded_item_indexes: [])
    analyze_result = response.fetch("analyzeResult")
    described_class.call(
      analyze_result:,
      profile: ReceiptAnalysisProfiles.fetch("JPN"),
      items: analyze_result.dig("documents", 0, "fields", "Items", "valueArray"),
      reference_pricing_candidates: references,
      item_calculation_mode_candidates: carriers,
      excluded_item_indexes:
    )
  end

  def parsed_sources(response = parenthetical_response)
    result = parsed_result(response)
    [
      result.dig(:candidates, :reference_pricing_candidates),
      result.dig(:candidates, :item_calculation_mode_candidates)
    ]
  end

  it "native candidateがexactに証明した購入数量単位だけを対応Itemへ反映する" do
    result = parsed_result
    references = result.dig(:candidates, :reference_pricing_candidates)
    items = result.dig(:candidates, :items)

    aggregate_failures do
      expect(references.pluck(:validation_state)).to eq(%w[valid valid])
      expect(references.map { |candidate| candidate.dig(:purchased_quantity, :unit_code) }).to eq(
        %w[liter liter]
      )
      expect(items.first(2)).to contain_exactly(
        include(quantity: "2.5", quantity_unit_code: "liter", quantity_unit_status: "known"),
        include(quantity: "2", quantity_unit_code: "liter", quantity_unit_status: "known")
      )
      expect(items.last).to include(quantity: 1.0, quantity_unit_code: "each", quantity_unit_status: "known")
    end
  end

  it "provider responseと候補を変更せずbounded overlayだけを返す" do
    response = parenthetical_response
    references, carriers = parsed_sources(response)
    originals = [ response.deep_dup, references.deep_dup, carriers.deep_dup ]

    overlays = extract_overlays(response:, references:, carriers:)

    aggregate_failures do
      expect(overlays).to eq(
        0 => { amount: "2.5", unit_code: "liter", unit_status: "known" },
        1 => { amount: "2", unit_code: "liter", unit_status: "known" }
      )
      expect([ response, references, carriers ]).to eq(originals)
    end
  end

  it "unpromoted・不正値・span不整合のcandidateをItemへ反映しない" do
    response = parenthetical_response
    references, carriers = parsed_sources(response)
    ambiguous = references.map(&:deep_dup)
    ambiguous.first.merge!(validation_state: "ambiguous", rejection_reasons: [ "ambiguous_tax_inclusion" ])
    malformed_amount = references.map(&:deep_dup)
    malformed_amount.first[:purchased_quantity][:amount] = "2.5x"
    malformed_span = references.map(&:deep_dup)
    malformed_span.first.dig(:purchased_quantity, :evidence)[:provider_span_end] = 10_000_001
    unknown_unit = references.map(&:deep_dup)
    unknown_unit.first[:purchased_quantity].merge!(unit_code: "unknown", unit_status: "unknown")

    [ ambiguous, malformed_amount, malformed_span, unknown_unit ].each do |invalid_references|
      expect(extract_overlays(response:, references: invalid_references, carriers:)).to eq({})
    end
  end

  it "candidate・destination carrierの重複またはidentity/path不一致をfail-closedにする" do
    response = parenthetical_response
    references, carriers = parsed_sources(response)
    duplicate_references = references + [ references.first.deep_dup ]
    duplicate_carriers = carriers + [ carriers.first.deep_dup ]
    wrong_identity = carriers.map(&:deep_dup)
    wrong_identity.first[:item_identity] = "azure_structured_item_i0_s0_e1"
    wrong_destination_path = carriers.map(&:deep_dup)
    wrong_destination_path.first[:source_field_path] = "documents[0].fields.Items[1]"
    wrong_path = references.map(&:deep_dup)
    wrong_path.first.dig(:purchased_quantity, :evidence)[:source_field_path] =
      "documents[0].fields.Items[1].Quantity"

    failures = [
      [ duplicate_references, carriers ],
      [ references, duplicate_carriers ],
      [ references, wrong_identity ],
      [ references, wrong_destination_path ],
      [ wrong_path, carriers ]
    ]
    failures.each do |invalid_references, invalid_carriers|
      overlays = extract_overlays(
        response:,
        references: invalid_references,
        carriers: invalid_carriers
      )

      expect(overlays).to eq({})
    end
  end

  it "分離したItem parent spanの間にあるcomponentを同一Itemとみなさない" do
    response = parenthetical_response
    references, carriers = parsed_sources(response)
    disjoint_parent = response.deep_dup
    item = disjoint_parent.dig(
      "analyzeResult", "documents", 0, "fields", "Items", "valueArray", 0
    )
    parent = item.fetch("spans").sole
    quantity = item.dig("valueObject", "Quantity", "spans", 0)
    parent_start = parent.fetch("offset")
    parent_end = parent_start + parent.fetch("length")
    quantity_start = quantity.fetch("offset")
    quantity_end = quantity_start + quantity.fetch("length")
    item["spans"] = [
      { "offset" => parent_start, "length" => quantity_start - parent_start },
      { "offset" => quantity_end, "length" => parent_end - quantity_end }
    ]

    expect(extract_overlays(response: disjoint_parent, references:, carriers:)).to eq({})
  end

  it "aggregate memberを部分反映せずlayout・line-group候補をnative Itemへ重ねない" do
    response = parenthetical_response
    references, carriers = parsed_sources(response)
    partially_invalid = references.map(&:deep_dup)
    partially_invalid.first.merge!(validation_state: "ambiguous", rejection_reasons: [ "ambiguous_tax_inclusion" ])
    layout = references.map { |candidate| candidate.deep_dup.merge(source_kind: "azure_item_layout") }
    line_group = references.map { |candidate| candidate.deep_dup.merge(source_kind: "azure_line_group") }

    invalid_inputs = [
      [ partially_invalid, [] ],
      [ layout, [] ],
      [ line_group, [] ],
      [ references, [ 0 ] ]
    ]
    invalid_inputs.each do |invalid_references, excluded_item_indexes|
      expect(
        extract_overlays(
          response:,
          references: invalid_references,
          carriers:,
          excluded_item_indexes:
        )
      ).to eq({})
    end

    unsupported = response.deep_dup
    unsupported.fetch("analyzeResult")["stringIndexType"] = "utf8Byte"
    measurement_unit = response.deep_dup
    measurement_unit.dig(
      "analyzeResult", "documents", 0, "fields", "Items", "valueArray", 0,
      "valueObject", "QuantityUnit"
    )["valueString"] = "L"

    aggregate_failures do
      expect(extract_overlays(response: unsupported, references:, carriers:)).to eq({})
      expect(extract_overlays(response: measurement_unit, references:, carriers:)).to eq({})
    end
  end
end
