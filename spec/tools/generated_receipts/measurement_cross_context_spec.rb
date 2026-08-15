# frozen_string_literal: true

require "rails_helper"
require_relative "../../../tools/generated_receipts"

RSpec.describe "Generated receipt Measurement cross-context contract" do
  CROSS_CONTEXT_MANIFEST_PATH = Rails.root.join(
    "spec/fixtures/generated_receipts/cross_context/measurement_candidate_boundaries.json"
  ).freeze
  PRINTED_UNIT_TOKENS = {
    "gram" => "g",
    "kilogram" => "kg",
    "milligram" => "mg",
    "liter" => "L",
    "milliliter" => "ml",
    "cubic_centimeter" => "cc",
    "lb" => "lb",
    "杯" => "杯"
  }.freeze

  def load_case(case_id)
    path = GeneratedReceipts.case_paths.find do |candidate_path|
      File.basename(candidate_path, ".json") == case_id
    end
    raise "Generated receipt case not found: #{case_id}" unless path

    case_data = GeneratedReceipts::Validator.load_file(path)
    validation = GeneratedReceipts::Validator.call(case_data)

    expect(validation.errors).to eq([])
    case_data
  end

  def source_item(case_data)
    case_data.fetch("source").fetch("items").sole
  end

  def expected_item(case_data)
    case_data.fetch("expected").fetch("items").sole
  end

  def expected_projection(case_data)
    case_data.fetch("expected").fetch("measurement_projections").sole
  end

  def cross_context_manifest
    @cross_context_manifest ||= JSON.parse(CROSS_CONTEXT_MANIFEST_PATH.read)
  end

  def cross_context_scenario(scenario_id)
    cross_context_manifest.fetch("scenarios").find do |scenario|
      scenario.fetch("scenario_id") == scenario_id
    end || raise("Cross-context scenario not found: #{scenario_id}")
  end

  def amount_item(case_data, pricing_source_kind: "reference_quantity_price")
    source = source_item(case_data)
    item = expected_item(case_data)

    {
      pricing_source_kind: pricing_source_kind,
      reference_price_amount: source.fetch("reference_price_amount"),
      reference_quantity: source.fetch("reference_quantity"),
      reference_quantity_unit_code: source.fetch("reference_unit"),
      reference_quantity_unit_raw: nil,
      reference_price_tax_inclusion: source.fetch("reference_price_tax_inclusion"),
      quantity: source.fetch("purchased_quantity"),
      quantity_unit_code: source.fetch("purchased_unit"),
      quantity_unit_raw: nil,
      price: nil,
      original_line_total: source["printed_line_total"],
      line_total: source["printed_line_total"],
      tax_rate: decimal_or_nil(item["tax_rate"]),
      discount_rate: decimal_or_nil(source["discount_rate"]),
      discount_amount: source["discount_amount"]
    }.compact
  end

  def call_amount(case_data, context:, item: amount_item(case_data))
    ReceiptAmountService.call(
      receipt: {},
      receipt_items: [ item ],
      receipt_tax_details: [],
      receipt_adjustments: [],
      receipt_payments: [],
      context: context,
      tax_rounding_mode: :floor,
      discount_rounding_mode: :round
    )
  end

  def decimal_or_nil(value)
    BigDecimal(value.to_s) unless value.nil?
  end

  def extract_manifest_candidates(scenario)
    Ocr::ResponseParser::ReferencePricingCandidateExtractor.call(
      items: azure_items_for(scenario),
      profile: ReceiptAnalysisProfiles.fetch("JPN"),
      projection: method(:independent_candidate_projection)
    )
  end

  def independent_candidate_projection(
    reference_price_amount:,
    reference_quantity:,
    reference_unit_code:,
    purchased_quantity:,
    purchased_unit_code:
  )
    projection = GeneratedReceipts::MeasurementContract.project(
      source_item: {
        "reference_price_amount" => reference_price_amount,
        "reference_quantity" => reference_quantity,
        "reference_unit" => reference_unit_code,
        "purchased_quantity" => purchased_quantity,
        "purchased_unit" => purchased_unit_code,
        "reference_price_tax_inclusion" => "gross"
      },
      tax_rate: "0",
      tax_rounding: "floor",
      discount_rounding: "round"
    )
    raise ArgumentError, "unprojectable candidate" unless projection

    {
      exact_amount: projection.exact_reference_amount,
      projected_amount: projection.projected_reference_line_total
    }
  end

  def azure_items_for(scenario)
    items = scenario.fetch("source_items").map.with_index do |source, index|
      build_azure_item(source, base_offset: index * 1_000)
    end
    apply_manifest_association!(items, scenario["association"])
    items
  end

  def build_azure_item(source, base_offset:)
    content = source.fetch("printed_lines").join("\n")
    item = {
      "content" => content,
      "spans" => [ { "offset" => base_offset, "length" => utf16_length(content) } ],
      "valueObject" => {}
    }
    add_quantity_field!(item, source, base_offset: base_offset)
    add_total_price_field!(item, source, base_offset: base_offset)
    item
  end

  def add_quantity_field!(item, source, base_offset:)
    quantity_token = if source["purchased_quantity"] && source["purchased_unit"]
      unit = PRINTED_UNIT_TOKENS.fetch(source.fetch("purchased_unit"), source.fetch("purchased_unit"))
      "#{source.fetch("purchased_quantity")}#{unit}"
    else
      item.fetch("content").lines.map(&:strip).find { |line| line.match?(/\A\d+(?:\.\d+)?\p{L}+\z/u) }
    end
    return unless quantity_token

    local_offset = item.fetch("content").rindex(quantity_token)
    return unless local_offset

    unit = quantity_token[/\p{L}+\z/u]
    item.fetch("valueObject")["Quantity"] = {
      "content" => quantity_token,
      "spans" => [
        {
          "offset" => provider_offset(item.fetch("content"), base_offset, local_offset),
          "length" => utf16_length(quantity_token)
        }
      ]
    }
    item.fetch("valueObject")["QuantityUnit"] = { "valueString" => unit }
  end

  def add_total_price_field!(item, source, base_offset:)
    return unless source.key?("printed_line_total")

    total_line = source.fetch("printed_lines").reverse.find { |line| line.include?("¥") }
    return unless total_line

    local_offset = item.fetch("content").rindex(total_line)
    item.fetch("valueObject")["TotalPrice"] = {
      "content" => total_line,
      "spans" => [
        {
          "offset" => provider_offset(item.fetch("content"), base_offset, local_offset),
          "length" => utf16_length(total_line)
        }
      ]
    }
  end

  def apply_manifest_association!(items, association)
    return items unless association&.fetch("kind", nil) == "overlapping_item_span"

    candidate_item = items.fetch(association.fetch("candidate_item_index"))
    adjacent_item = items.fetch(association.fetch("adjacent_item_index"))
    quantity_offset = candidate_item.fetch("content").index("342g")
    adjacent_item.fetch("spans").first["offset"] = provider_offset(
      candidate_item.fetch("content"),
      candidate_item.dig("spans", 0, "offset"),
      quantity_offset
    )
    items
  end

  def provider_offset(text, base_offset, character_offset)
    base_offset + utf16_length(text[0...character_offset])
  end

  def utf16_length(value)
    value.to_s.encode(Encoding::UTF_16LE).bytesize / 2
  end

  it "uses the fixture source as manual reference authority and matches its independent projection" do
    case_data = load_case("g116_reference_per_500ml")
    source = source_item(case_data)
    projection = expected_projection(case_data)

    result = call_amount(case_data, context: :manual)
    computed_item = result.dig(:computed, :items).sole

    aggregate_failures do
      expect(computed_item).to include(
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: source.fetch("reference_price_amount"),
        reference_quantity: source.fetch("reference_quantity"),
        reference_quantity_unit_code: source.fetch("reference_unit"),
        reference_price_tax_inclusion: source.fetch("reference_price_tax_inclusion"),
        original_line_total: projection.fetch("projected_reference_line_total"),
        line_total: projection.fetch("projected_gross_line_total")
      )
      expect(result.dig(:resolved, :total)).to eq(projection.fetch("projected_gross_line_total"))
    end
  end

  it "keeps an explicit printed total authoritative when its diagnostic projection disagrees" do
    case_data = load_case("g122_printed_total_mismatch")
    source = source_item(case_data)
    projection = expected_projection(case_data)
    printed_total = source.fetch("printed_line_total")
    explicit_item = amount_item(case_data, pricing_source_kind: "explicit_line_total").merge(
      original_line_total: printed_total,
      line_total: printed_total
    )

    result = call_amount(case_data, context: :analysis, item: explicit_item)
    computed_item = result.dig(:computed, :items).sole

    aggregate_failures do
      expect(projection.fetch("projected_reference_line_total")).not_to eq(printed_total)
      expect(computed_item).to include(
        pricing_source_kind: "explicit_line_total",
        original_line_total: printed_total,
        line_total: printed_total
      )
      expect(result.dig(:resolved, :total)).to eq(printed_total)
    end
  end

  it "keeps edit-save source amounts separate from the gross candidate projection" do
    case_data = load_case("g121_reference_net_discount")
    source = source_item(case_data)
    projection = expected_projection(case_data)

    result = call_amount(case_data, context: :edit_save)
    source_result = result.dig(:computed, :source_items).sole
    projected_result = result.dig(:computed, :items).sole

    aggregate_failures do
      expect(source_result).to include(
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: source.fetch("reference_price_amount"),
        reference_quantity: source.fetch("reference_quantity"),
        reference_quantity_unit_code: source.fetch("reference_unit"),
        reference_price_tax_inclusion: "net",
        original_line_total: projection.fetch("projected_reference_line_total"),
        discount_amount: projection.fetch("discount_amount"),
        line_total: projection.fetch("discounted_source_line_total")
      )
      expect(projected_result[:line_total]).to eq(projection.fetch("projected_gross_line_total"))
      expect(source_result[:line_total]).not_to eq(projected_result[:line_total])
    end
  end

  it "carries the weighted OCR candidate to BuildParams without adopting ReceiptItem authority" do
    case_data = load_case("g113_reference_per_100g")
    generated_source = source_item(case_data)
    generated_projection = expected_projection(case_data)
    raw_response = JSON.parse(Rails.root.join("spec/fixtures/ocr/weighted_units_receipt.json").read)
    ocr_result = Ocr::ResponseParser.new(response: raw_response, provider: :fixture).call
    candidate = ocr_result.dig(:candidates, :reference_pricing_candidates).first

    params = Analysis::ReceiptBuildParamsService.call(ocr_result: ocr_result, ai_result: nil)
    item = params.fetch(:receipt_items_attributes).fetch(candidate.fetch(:item_index))

    aggregate_failures do
      expect(candidate).to include(
        validation_state: "ambiguous",
        rejection_reasons: [ "ambiguous_tax_inclusion" ]
      )
      expect(candidate.dig(:reference_price, :amount)).to eq(generated_source.fetch("reference_price_amount"))
      expect(candidate.dig(:reference_quantity, :amount)).to eq(generated_source.fetch("reference_quantity"))
      expect(candidate.dig(:reference_quantity, :unit_code)).to eq(generated_source.fetch("reference_unit"))
      expect(candidate.dig(:purchased_quantity, :amount)).to eq(generated_source.fetch("purchased_quantity"))
      expect(candidate.dig(:purchased_quantity, :unit_code)).to eq(generated_source.fetch("purchased_unit"))
      expect(candidate.dig(:corroboration, :projected_amount)).to eq(
        generated_projection.fetch("projected_reference_line_total")
      )
      expect(candidate.dig(:printed_line_total, :amount)).to eq("5061")
      expect(params.fetch(:reference_pricing_candidates)).to include(candidate)
      expect(item[:line_total]).to eq(5061)
      expect(item).not_to include(
        :pricing_source_kind,
        :reference_price_amount,
        :reference_quantity,
        :reference_quantity_unit_code,
        :reference_price_tax_inclusion
      )
    end
  end

  it "keeps g017 on the legacy contract and does not infer a formula from its arithmetic" do
    case_data = load_case("g017_normal_weighted_kg")
    fixture_item = case_data.fetch("expected").fetch("items").first
    legacy_total = fixture_item.fetch("line_total")
    legacy_item = {
      pricing_source_kind: nil,
      price: fixture_item.fetch("unit_price") + 1,
      quantity: fixture_item.fetch("quantity"),
      quantity_unit_code: "kilogram",
      original_line_total: legacy_total,
      line_total: legacy_total,
      tax_rate: BigDecimal("0")
    }

    result = call_amount(case_data, context: :edit_save, item: legacy_item)
    source_result = result.dig(:computed, :source_items).sole

    aggregate_failures do
      expect(case_data).not_to have_key("source")
      expect(fixture_item).not_to include(
        "quantity_unit_code",
        "pricing_source_kind",
        "reference_price_amount",
        "reference_quantity",
        "reference_quantity_unit_code"
      )
      expect(source_result).to include(
        pricing_source_kind: nil,
        original_line_total: legacy_total,
        line_total: legacy_total
      )
    end
  end

  it "uses a no-total source as manual authority but keeps it candidate-only in analysis" do
    scenario = cross_context_scenario("formula_without_printed_item_total")
    source = scenario.fetch("source_items").sole
    expected_projection = scenario.fetch("expected_projection")
    expected_contexts = scenario.fetch("expected_contexts")
    manual_item = {
      pricing_source_kind: "reference_quantity_price",
      reference_price_amount: source.fetch("reference_price_amount"),
      reference_quantity: source.fetch("reference_quantity"),
      reference_quantity_unit_code: source.fetch("reference_unit"),
      reference_price_tax_inclusion: source.fetch("reference_price_tax_inclusion"),
      reference_quantity_unit_raw: nil,
      quantity: source.fetch("purchased_quantity"),
      quantity_unit_code: source.fetch("purchased_unit"),
      quantity_unit_raw: nil,
      tax_rate: BigDecimal("0.1")
    }

    manual_result = ReceiptAmountService.call(
      receipt: {},
      receipt_items: [ manual_item ],
      receipt_tax_details: [],
      context: :manual
    )
    manual_computed = manual_result.dig(:computed, :items).sole

    candidates = extract_manifest_candidates(scenario)
    expected_candidate = scenario.fetch("expected_candidates").sole
    analysis_source_item = {
      raw_text: source.fetch("printed_lines").join("\n"),
      price: source.fetch("reference_price_amount").to_i,
      quantity: BigDecimal(source.fetch("purchased_quantity")),
      quantity_unit_code: source.fetch("purchased_unit"),
      quantity_unit_status: "known",
      original_line_total: nil,
      line_total: nil,
      confidence: BigDecimal("0.99")
    }
    analysis_params = Analysis::ReceiptBuildParamsService.call(
      ocr_result: {
        candidates: {
          items: [ analysis_source_item ],
          reference_pricing_candidates: candidates
        },
        lines: source.fetch("printed_lines")
      },
      ai_result: nil
    )
    analysis_item = analysis_params.fetch(:receipt_items_attributes).sole
    candidate = candidates.sole

    aggregate_failures do
      expect(scenario.fetch("contexts")).to match_array(%w[manual_formula analysis])
      expect(source).not_to have_key("printed_line_total")
      expect(manual_item).not_to include(:original_line_total, :line_total)
      expect(manual_computed).to include(
        pricing_source_kind: expected_contexts.dig("manual_formula", "pricing_source_kind"),
        original_line_total: expected_projection.fetch("projected_reference_line_total"),
        line_total: expected_contexts.dig("manual_formula", "line_total")
      )
      expect(expected_contexts.dig("manual_formula", "reference_source_preserved")).to be(true)
      expect(candidate).to include(
        validation_state: expected_candidate.fetch("validation_state"),
        rejection_reasons: expected_candidate.fetch("rejection_reasons")
      )
      expect(candidate.dig(:reference_price, :amount)).to eq(expected_candidate.fetch("reference_price_amount"))
      expect(candidate.dig(:reference_quantity, :amount)).to eq(expected_candidate.fetch("reference_quantity"))
      expect(candidate.dig(:reference_quantity, :unit_code)).to eq(expected_candidate.fetch("reference_unit_code"))
      expect(candidate.dig(:purchased_quantity, :amount)).to eq(expected_candidate.fetch("purchased_quantity"))
      expect(candidate.dig(:purchased_quantity, :unit_code)).to eq(expected_candidate.fetch("purchased_unit_code"))
      expect(candidate[:printed_line_total]).to eq(expected_candidate.fetch("printed_line_total"))
      expect(expected_candidate.fetch("projected_line_total")).to eq(
        expected_projection.fetch("projected_reference_line_total")
      )
      expect(analysis_params.fetch(:reference_pricing_candidates)).to eq(candidates)
      expect(analysis_item).to include(line_total: expected_contexts.dig("analysis", "line_total"))
      expect(analysis_item).not_to include(
        :pricing_source_kind,
        :reference_price_amount,
        :reference_quantity,
        :reference_quantity_unit_code,
        :reference_price_tax_inclusion
      )
      expect(expected_contexts.dig("analysis", "reference_source_persisted")).to be(false)
      expect(scenario.fetch("expected_persisted_authority")).to eq("none_in_analysis")
      expect(scenario.fetch("automatic_adoption")).to be(false)
    end
  end

  it "executes every negative candidate-boundary manifest scenario through the Q6 extractor" do
    negative_scenarios = cross_context_manifest.fetch("scenarios").reject do |scenario|
      scenario.fetch("scenario_id") == "formula_without_printed_item_total"
    end

    aggregate_failures do
      expect(negative_scenarios.size).to eq(9)
      expected_states = cross_context_manifest.fetch("scenarios").flat_map do |scenario|
        scenario.fetch("expected_candidates").map { |candidate| candidate.fetch("validation_state") }
      end
      expect(expected_states.uniq).to match_array(cross_context_manifest.fetch("candidate_states"))
      negative_scenarios.each do |scenario|
        candidates_by_index = extract_manifest_candidates(scenario).index_by { |candidate| candidate.fetch(:item_index) }
        actual = scenario.fetch("expected_candidates").map do |expected|
          candidate = candidates_by_index[expected.fetch("item_index")]
          if candidate
            {
              "item_index" => candidate.fetch(:item_index),
              "validation_state" => candidate.fetch(:validation_state),
              "rejection_reasons" => candidate.fetch(:rejection_reasons)
            }
          else
            {
              "item_index" => expected.fetch("item_index"),
              "validation_state" => "none",
              "rejection_reasons" => []
            }
          end
        end

        expect(actual).to eq(scenario.fetch("expected_candidates")), scenario.fetch("scenario_id")
        expect(scenario.fetch("expected_persisted_authority")).to eq("none")
      end
    end
  end
end
