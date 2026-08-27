# frozen_string_literal: true

require "bigdecimal"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "tempfile"
require "timeout"
require_relative "../../../tools/generated_receipts"

RSpec.describe "Generated receipt adversarial contract" do
  TIMEOUT_SECONDS = 1

  def load_measurement_case(name = "g116_reference_per_500ml")
    GeneratedReceipts::Validator.load_file(
      File.join(
        GeneratedReceipts::MEASUREMENT_CASES_DIR,
        "#{name}.json"
      )
    )
  end

  def load_legacy_case
    GeneratedReceipts::Validator.load_file(
      File.join(GeneratedReceipts::CASES_DIR, "g001_normal_included_10_cash.json")
    )
  end

  def deep_dup(value)
    JSON.parse(JSON.generate(value))
  end

  def bounded_call(&)
    Timeout.timeout(TIMEOUT_SECONDS, &)
  end

  describe "generated receipt JSON schema bounds" do
    it "mirrors the approved runtime collection, span, and candidate bounds" do
      schema = JSON.parse(
        File.read(File.join(GeneratedReceipts::ROOT, "case_schema.json"))
      )
      expected_properties = schema.dig("properties", "expected", "properties")
      source_item_schema = schema.dig(
        "properties", "source", "properties", "items", "items"
      )
      candidate_schema = expected_properties.dig("reference_pricing_candidates", "items")

      aggregate_failures do
        expect(expected_properties.dig("items", "maxItems")).to eq(100)
        expect(expected_properties.dig("measurement_projections", "maxItems")).to eq(100)
        expect(expected_properties.dig("reference_pricing_candidates", "maxItems")).to eq(100)
        expect(schema.dig("properties", "source", "properties", "items", "maxItems")).to eq(100)
        expect(source_item_schema.dig("properties", "item_index", "maximum")).to eq(99)
        expect(source_item_schema.dig("properties", "printed_lines", "maxItems")).to eq(100)
        expect(source_item_schema.dig("properties", "printed_lines", "items", "maxLength")).to eq(512)
        expect(candidate_schema.dig("properties", "item_index", "maximum")).to eq(99)
        expect(candidate_schema.dig("properties", "rejection_reasons", "maxItems")).to eq(8)
        expect(candidate_schema.dig("properties", "rounding_matches", "maxItems")).to eq(3)
      end
    end

    it "keeps case IDs path-safe and bounded" do
      schema = JSON.parse(
        File.read(File.join(GeneratedReceipts::ROOT, "case_schema.json"))
      )
      case_id_schema = schema.dig("properties", "case_id")

      aggregate_failures do
        expect(case_id_schema["maxLength"]).to eq(64)
        expect(Regexp.new(case_id_schema.fetch("pattern"))).to match(
          "g122_printed_total_mismatch"
        )
        expect(Regexp.new(case_id_schema.fetch("pattern"))).not_to match("../../receipt")
      end
    end
  end

  describe GeneratedReceipts::Validator do
    it "returns validation errors instead of raising for malformed root JSON shapes" do
      aggregate_failures do
        [ nil, [], "receipt", 1, true ].each do |value|
          result = bounded_call { described_class.call(value) }

          expect(result).not_to be_valid
          expect(result.errors).to include("case: must be an object")
        end
      end
    end

    it "returns structural errors instead of raising for malformed Measurement entries" do
      mutations = {
        "expected.items[0]" => ->(data) { data["expected"]["items"][0] = nil },
        "source.items[0]" => ->(data) { data["source"]["items"][0] = nil },
        "expected.measurement_projections[0]" => lambda { |data|
          data["expected"]["measurement_projections"][0] = nil
        },
        "expected.reference_pricing_candidates[0]" => lambda { |data|
          data["expected"]["reference_pricing_candidates"][0] = nil
        }
      }

      aggregate_failures do
        mutations.each do |path, mutate|
          data = deep_dup(load_measurement_case)
          mutate.call(data)

          result = bounded_call { described_class.call(data) }

          expect(result).not_to be_valid, path
          expect(result.errors).to include("#{path}: must be an object"), path
        end
      end
    end

    it "does not echo an arbitrary unknown key into validation errors" do
      sensitive_key = "unexpected\nprivate-receipt-evidence"
      data = deep_dup(load_legacy_case)
      data[sensitive_key] = true

      result = bounded_call { described_class.call(data) }

      aggregate_failures do
        expect(result).not_to be_valid
        expect(result.errors).to include("case.invalid_key: is not allowed")
        expect(result.errors.join).not_to include(sensitive_key, "private-receipt-evidence")
      end
    end

    it "fails closed across wrong Q7 field types and missing required fields" do
      mutations = [
        ->(data) { data["source"] = [] },
        ->(data) { data["expected"] = [] },
        ->(data) { data["source"]["items"][0]["printed_lines"] = {} },
        ->(data) { data["source"]["items"][0]["purchased_quantity"] = [] },
        ->(data) { data["source"]["items"][0]["purchased_unit"] = {} },
        ->(data) { data["source"]["items"][0]["reference_price_amount"] = true },
        ->(data) { data["expected"]["measurement_projections"][0]["exact_reference_amount"] = [] },
        lambda do |data|
          data["expected"]["measurement_projections"][0]["projected_reference_line_total"] = "360"
        end,
        ->(data) { data["expected"]["reference_pricing_candidates"][0]["validation_state"] = [] },
        ->(data) { data["expected"]["reference_pricing_candidates"][0]["rejection_reasons"] = {} },
        ->(data) { data["expected"]["reference_pricing_candidates"][0]["reference_quantity"] = {} },
        lambda do |data|
          data["expected"]["reference_pricing_candidates"][0]["reference_price_tax_inclusion"] = {}
        end,
        ->(data) { data["source"]["items"][0].delete("purchased_quantity") },
        ->(data) { data["expected"]["measurement_projections"][0].delete("item_index") },
        ->(data) { data["expected"]["reference_pricing_candidates"][0].delete("validation_state") }
      ]

      aggregate_failures do
        mutations.each_with_index do |mutate, index|
          data = deep_dup(load_measurement_case)
          mutate.call(data)

          result = bounded_call { described_class.call(data) }

          expect(result).not_to be_valid, "mutation #{index}"
        end
      end
    end

    it "rejects wrong scalar and label types before rendering or comparison" do
      mutations = {
        "intent" => ->(data) { data["intent"] = {} },
        "expected.store_name" => ->(data) { data["expected"]["store_name"] = [] },
        "expected.subtotal" => ->(data) { data["expected"]["subtotal"] = "800" },
        "expected.status" => ->(data) { data["expected"]["status"] = 1 },
        "expected.payment_method" => ->(data) { data["expected"]["payment_method"] = "cash\n" },
        "expected.review_reasons" => ->(data) { data["expected"]["review_reasons"] = [ 1 ] },
        "expected.items[0].name" => ->(data) { data["expected"]["items"][0]["name"] = {} },
        "expected.items[0].unit_price" => ->(data) { data["expected"]["items"][0]["unit_price"] = "550" },
        "expected.items[0].line_total" => ->(data) { data["expected"]["items"][0]["line_total"] = "550" },
        "expected.items[0].quantity_unit_code" => lambda do |data|
          data["expected"]["items"][0]["quantity_unit_code"] = {}
        end,
        "expected.tax_details[0].rate" => ->(data) { data["expected"]["tax_details"][0]["rate"] = "0.1" },
        "expected.tax_details[0].label" => ->(data) { data["expected"]["tax_details"][0]["label"] = {} },
        "expected.payments[0].label" => ->(data) { data["expected"]["payments"][0]["label"] = {} },
        "expected.payments[0].amount" => ->(data) { data["expected"]["payments"][0]["amount"] = "880" },
        "render.custom_lines" => ->(data) { data["render"]["custom_lines"] = [ {} ] },
        "degradation.enabled" => ->(data) { data["degradation"]["enabled"] = "false" },
        "assertions.allow_review_reasons" => ->(data) { data["assertions"]["allow_review_reasons"] = {} }
      }

      aggregate_failures do
        mutations.each do |path, mutate|
          data = deep_dup(load_legacy_case)
          mutate.call(data)
          actual = GeneratedReceipts::ComparisonRunner.expected_snapshot(data)

          validation = bounded_call { described_class.call(data) }
          comparison = bounded_call { GeneratedReceipts::Comparator.call(data, actual) }

          expect(validation).not_to be_valid, path
          expect(validation.errors).to include(a_string_starting_with(path)), path
          expect(comparison.diffs).to contain_exactly(
            hash_including(path: "comparison_input", severity: "FAIL")
          ), path
        end
      end
    end

    it "rejects missing, orphaned, and duplicate item associations" do
      mutations = [
        lambda do |data|
          data["source"]["items"] = []
          [ "source.items: item indexes must exactly cover expected.items" ]
        end,
        lambda do |data|
          data["expected"]["measurement_projections"][0]["item_index"] = 9
          [ "expected.measurement_projections: item indexes must exactly match source.items" ]
        end,
        lambda do |data|
          data["source"]["items"] << deep_dup(data["source"]["items"][0])
          [ "source.items: has duplicate item_index 0" ]
        end,
        lambda do |data|
          candidates = data["expected"]["reference_pricing_candidates"]
          candidates << deep_dup(candidates[0])
          [ "expected.reference_pricing_candidates: has duplicate item_index 0" ]
        end
      ]

      aggregate_failures do
        mutations.each do |mutate|
          data = deep_dup(load_measurement_case)
          expected_errors = mutate.call(data)

          result = bounded_call { described_class.call(data) }

          expect(result).not_to be_valid
          expected_errors.each { |error| expect(result.errors).to include(error) }
        end
      end
    end

    it "rejects duplicate rejection reasons instead of relying on schema-only uniqueness" do
      data = deep_dup(load_measurement_case)
      candidate = data["expected"]["reference_pricing_candidates"][0]
      candidate["validation_state"] = "ambiguous"
      candidate["rejection_reasons"] = Array.new(2, "ambiguous_reference_expression")

      result = bounded_call { described_class.call(data) }

      expect(result.errors).to include(
        "expected.reference_pricing_candidates[0].rejection_reasons: must contain unique values"
      )
    end

    it "rejects non-integer, negative, and out-of-range item indexes without sorting errors" do
      aggregate_failures do
        [ "0", -1, 100 ].each do |item_index|
          data = deep_dup(load_measurement_case)
          data["source"]["items"][0]["item_index"] = item_index

          result = bounded_call { described_class.call(data) }

          expect(result).not_to be_valid
          expect(result.errors).to include(
            "source.items[0].item_index: must be an integer between 0 and 99"
          )
        end
      end
    end

    it "bounds Measurement collections, evidence lines, and candidate reason counts" do
      cases = {
        "source.items" => lambda { |data|
          data["source"]["items"] = Array.new(101) do |index|
            data["source"]["items"][0].merge("item_index" => index)
          end
        },
        "expected.measurement_projections" => lambda { |data|
          data["expected"]["measurement_projections"] = Array.new(101) do |index|
            data["expected"]["measurement_projections"][0].merge("item_index" => index)
          end
        },
        "expected.reference_pricing_candidates" => lambda { |data|
          data["expected"]["reference_pricing_candidates"] = Array.new(101) do |index|
            data["expected"]["reference_pricing_candidates"][0].merge("item_index" => index)
          end
        },
        "source.items[0].printed_lines" => lambda { |data|
          data["source"]["items"][0]["printed_lines"] = Array.new(101, "x")
        },
        "expected.reference_pricing_candidates[0].rejection_reasons" => lambda { |data|
          candidate = data["expected"]["reference_pricing_candidates"][0]
          candidate["validation_state"] = "ambiguous"
          candidate["rejection_reasons"] = Array.new(9, "ambiguous_reference_expression")
        }
      }

      aggregate_failures do
        cases.each do |path, mutate|
          data = deep_dup(load_measurement_case)
          mutate.call(data)

          result = bounded_call { described_class.call(data) }

          expect(result).not_to be_valid, path
          expect(result.errors).to include(a_string_starting_with("#{path}: has more than")), path
        end
      end
    end

    it "rejects invalid encoding, NUL, oversized lines, and oversized item evidence" do
      invalid_lines = [
        [ "\xFF".b ],
        [ "item\u0000price" ],
        [ "item\u0085price" ],
        [ "item\nprice" ],
        [ "x" * 513 ],
        Array.new(9, "x" * 500)
      ]

      aggregate_failures do
        invalid_lines.each do |printed_lines|
          data = deep_dup(load_measurement_case)
          data["source"]["items"][0]["printed_lines"] = printed_lines

          result = bounded_call { described_class.call(data) }

          expect(result).not_to be_valid, printed_lines.map(&:bytesize).inspect
          expect(result.errors).to include(
            a_string_starting_with("source.items[0].printed_lines:")
          )
        end
      end
    end

    it "rejects candidate, projection, and persisted-authority mutations" do
      mutations = [
        lambda do |data|
          data["expected"]["reference_pricing_candidates"][0]["reference_price_amount"] = "999"
        end,
        lambda do |data|
          data["expected"]["measurement_projections"][0]["projected_reference_line_total"] = 999
        end,
        ->(data) { data["expected"]["items"][0]["original_line_total"] = 999 },
        lambda do |data|
          data["expected"]["items"][0]["pricing_source_kind"] = "reference_quantity_price"
        end,
        ->(data) { data["expected"]["items"][0]["pricing_source_kind"] = "invented" }
      ]

      aggregate_failures do
        mutations.each do |mutate|
          data = deep_dup(load_measurement_case)
          mutate.call(data)

          expect(bounded_call { described_class.call(data) }).not_to be_valid
        end
      end
    end

    it "does not establish formula authority for unknown or cross-dimension units" do
      aggregate_failures do
        %w[parsec gram].each do |unit|
          data = deep_dup(load_measurement_case)
          data["source"]["context"] = "manual"
          data["source"]["items"][0]["purchased_unit"] = unit
          data["expected"]["items"][0].merge!(
            "quantity_unit_code" => unit == "parsec" ? "each" : unit,
            "pricing_source_kind" => "reference_quantity_price",
            "reference_price_amount" => "120",
            "reference_quantity" => "500",
            "reference_quantity_unit_code" => "milliliter",
            "reference_price_tax_inclusion" => "gross"
          )

          result = bounded_call { described_class.call(data) }

          expect(result).not_to be_valid
          expect(result.errors).to include(
            "source.items[0]: must be independently projectable for manual reference authority"
          )
        end
      end
    end

    it "rejects oversized exact decimal source values in bounded time" do
      data = deep_dup(load_measurement_case)
      data["source"]["items"][0]["reference_price_amount"] = "9" * 100_000
      data["expected"]["reference_pricing_candidates"][0]["reference_price_amount"] = "9" * 100_000

      result = bounded_call { described_class.call(data) }

      expect(result).not_to be_valid
      expect(result.errors).to include(
        "source.items[0].reference_price_amount: must be an exact decimal within the approved bounds"
      )
    end

    it "rejects scientific notation before BigDecimal can expand it" do
      aggregate_failures do
        [ "1e0", "1e100000" ].each do |quantity|
          data = deep_dup(load_legacy_case)
          data["expected"]["items"][0]["quantity"] = quantity

          result = bounded_call { described_class.call(data) }

          expect(result).not_to be_valid, quantity
          expect(result.errors.join.bytesize).to be < 1_024, quantity
        end
      end
    end

    it "rejects unsafe case IDs through the runtime validator" do
      aggregate_failures do
        [ "../../receipt", "g001\nforged", "g001_#{'x' * 64}" ].each do |case_id|
          data = deep_dup(load_legacy_case)
          data["case_id"] = case_id

          result = bounded_call { described_class.call(data) }

          expect(result).not_to be_valid, case_id.inspect
          expect(result.errors).to include(
            "case_id: must be a path-safe generated receipt identifier"
          )
        end
      end
    end

    it "binds loaded case IDs to regular JSON files in the approved fixture roots" do
      Tempfile.create([ "renamed-case-", ".json" ], GeneratedReceipts::CASES_DIR) do |file|
        file.write(JSON.generate(load_legacy_case))
        file.flush

        expect do
          described_class.load_file(file.path)
        end.to raise_error(
          GeneratedReceipts::Validator::FixtureLoadError,
          GeneratedReceipts::Validator::FIXTURE_LOAD_ERROR_MESSAGE
        )
      end

      Tempfile.create([ "outside-root-", ".json" ]) do |file|
        file.write(JSON.generate(load_legacy_case))
        file.flush

        expect do
          described_class.load_file(file.path)
        end.to raise_error(
          GeneratedReceipts::Validator::FixtureLoadError,
          GeneratedReceipts::Validator::FIXTURE_LOAD_ERROR_MESSAGE
        )
      end
    end

    it "bounds file bytes and JSON nesting before validating parsed values" do
      oversized_bytes = (4 * 1024 * 1024) + 1
      cases = {
        "oversized" => " " * oversized_bytes,
        "nested" => ("[" * 17) + "0" + ("]" * 17)
      }

      aggregate_failures do
        expect(described_class::MAX_CASE_FILE_BYTES).to eq(4 * 1024 * 1024)
        expect(described_class::MAX_JSON_NESTING).to eq(16)

        cases.each do |label, payload|
          Tempfile.create([ "#{label}-", ".json" ], GeneratedReceipts::CASES_DIR) do |file|
            file.binmode
            file.write(payload)
            file.flush

            expect do
              bounded_call { described_class.load_file(file.path) }
            end.to raise_error(
              GeneratedReceipts::Validator::FixtureLoadError,
              GeneratedReceipts::Validator::FIXTURE_LOAD_ERROR_MESSAGE
            ), label
          end
        end
      end
    end

    it "rejects symlinked fixtures and invalid UTF-8 with the generic load error" do
      link_path = File.join(
        GeneratedReceipts::CASES_DIR,
        "g999_symlink_#{SecureRandom.hex(4)}.json"
      )
      File.symlink(
        File.join(GeneratedReceipts::CASES_DIR, "g001_normal_included_10_cash.json"),
        link_path
      )

      expect do
        described_class.load_file(link_path)
      end.to raise_error(
        GeneratedReceipts::Validator::FixtureLoadError,
        GeneratedReceipts::Validator::FIXTURE_LOAD_ERROR_MESSAGE
      )

      Tempfile.create([ "invalid-encoding-", ".json" ], GeneratedReceipts::CASES_DIR) do |file|
        file.binmode
        file.write("{\"case_id\":\"g999_invalid_\xFF\"}".b)
        file.flush

        expect do
          described_class.load_file(file.path)
        end.to raise_error(
          GeneratedReceipts::Validator::FixtureLoadError,
          GeneratedReceipts::Validator::FIXTURE_LOAD_ERROR_MESSAGE
        )
      end
    ensure
      File.unlink(link_path) if link_path && File.symlink?(link_path)
    end

    it "keeps safe case artifact paths inside their designated root" do
      path = described_class.artifact_path(
        root: GeneratedReceipts::IMAGES_DIR,
        case_id: "g122_printed_total_mismatch",
        extension: "png"
      )

      aggregate_failures do
        expect(path).to eq(
          File.join(
            GeneratedReceipts::IMAGES_DIR,
            "g122_printed_total_mismatch.png"
          )
        )
        expect do
          described_class.artifact_path(
            root: GeneratedReceipts::IMAGES_DIR,
            case_id: "../../receipt",
            extension: "png"
          )
        end.to raise_error(GeneratedReceipts::Validator::FixtureLoadError)
        [ "x" * 17, "x" * 100_000, "p\nng" ].each do |extension|
          expect do
            described_class.artifact_path(
              root: GeneratedReceipts::IMAGES_DIR,
              case_id: "g122_printed_total_mismatch",
              extension: extension
            )
          end.to raise_error(GeneratedReceipts::Validator::FixtureLoadError)
        end
      end
    end

    it "does not follow an existing artifact symlink outside its root" do
      case_id = "g999_artifact_#{SecureRandom.hex(4)}"
      link_path = File.join(GeneratedReceipts::IMAGES_DIR, "#{case_id}.png")

      Tempfile.create([ "outside-artifact-", ".png" ]) do |target|
        File.symlink(target.path, link_path)

        expect do
          described_class.artifact_path(
            root: GeneratedReceipts::IMAGES_DIR,
            case_id: case_id,
            extension: "png",
            must_exist: true
          )
        end.to raise_error(GeneratedReceipts::Validator::FixtureLoadError)
      ensure
        File.unlink(link_path) if File.symlink?(link_path)
      end
    end
  end

  describe GeneratedReceipts::MeasurementContract do
    def project(**overrides)
      described_class.project(
        source_item: {
          "purchased_quantity" => "1.5",
          "purchased_unit" => "liter",
          "reference_price_amount" => "120",
          "reference_quantity" => "500",
          "reference_unit" => "milliliter",
          "reference_price_tax_inclusion" => "gross"
        }.merge(overrides),
        tax_rate: "0.1",
        tax_rounding: "floor",
        discount_rounding: "round"
      )
    end

    it "rejects malformed source shapes and non-finite values without raising" do
      aggregate_failures do
        [ nil, [], "source", 1 ].each do |source_item|
          result = bounded_call do
            described_class.project(
              source_item: source_item,
              tax_rate: "0.1",
              tax_rounding: "floor",
              discount_rounding: "round"
            )
          end
          expect(result).to be_nil
        end

        expect(
          bounded_call do
            described_class.rounding_matches(
              exact_amount: Float::NAN,
              printed_line_total: 1
            )
          end
        ).to eq([])
        expect(project("purchased_unit" => Rational(1 << 100_000, 1))).to be_nil
      end
    end

    it "rejects huge String, BigDecimal, and Rational inputs in bounded time" do
      huge_digits = "9" * 100_000
      huge_rational = Rational(1 << 100_000, 1)
      oversized_string_class = Class.new(String) do
        def valid_encoding?
          raise "valid_encoding? must not inspect an oversized Measurement token"
        end
      end
      oversized = oversized_string_class.new("9" * 65)

      aggregate_failures do
        expect(bounded_call { project("reference_price_amount" => huge_digits) }).to be_nil
        expect { expect(project("reference_price_amount" => oversized)).to be_nil }.not_to raise_error
        expect(
          bounded_call { project("reference_price_amount" => BigDecimal("1E100000")) }
        ).to be_nil
        expect(bounded_call { project("reference_price_amount" => huge_rational) }).to be_nil
      end
    end

    it "does not accept Float as an exact Measurement source" do
      expect(project("reference_price_amount" => 120.0)).to be_nil
    end

    it "enforces the approved magnitude and projected-line-total bounds" do
      aggregate_failures do
        expect(project("reference_price_amount" => "1000000000000")).to be_nil
        expect(project("purchased_quantity" => "10000")).to be_nil
        expect(
          project(
            "reference_price_amount" => "999999999999",
            "reference_quantity" => "0.001",
            "purchased_quantity" => "9999.999",
            "purchased_unit" => "kilogram",
            "reference_unit" => "milligram"
          )
        ).to be_nil
      end
    end
  end

  describe GeneratedReceipts::Comparator do
    it "returns an explicit failure for malformed fixture-side comparison input" do
      valid_case = load_legacy_case
      malformed_cases = [
        nil,
        [],
        {},
        { "case_id" => "malformed" },
        deep_dup(valid_case).merge("expected" => nil),
        deep_dup(valid_case).merge("expected" => []),
        deep_dup(valid_case).tap { |data| data["expected"]["items"] = nil },
        deep_dup(valid_case).tap { |data| data["expected"]["items"] = [ nil ] },
        deep_dup(valid_case).tap do |data|
          data["expected"]["items"] = Array.new(101, data["expected"]["items"][0])
        end,
        deep_dup(valid_case).tap do |data|
          data["expected"]["reference_pricing_candidates"] = Array.new(
            101,
            { "item_index" => 0, "validation_state" => "none", "rejection_reasons" => [] }
          )
        end,
        deep_dup(valid_case).tap do |data|
          data["expected"]["items"][0]["quantity"] = "1e100000"
        end
      ]

      aggregate_failures do
        malformed_cases.each do |case_data|
          result = bounded_call { described_class.call(case_data, {}) }

          expect(result.status).to eq("FAIL")
          expect(result.diffs).to include(
            hash_including(path: "comparison_input", severity: "FAIL")
          )
        end
      end
    end

    it "does not let the same malformed numeric fixture value normalize into a false pass" do
      case_data = deep_dup(load_legacy_case)
      case_data["expected"]["items"][0]["quantity"] = "1e100000"
      actual = GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data)

      result = bounded_call { described_class.call(case_data, actual) }

      aggregate_failures do
        expect(result.status).to eq("FAIL")
        expect(result.diffs).to contain_exactly(
          hash_including(path: "comparison_input", severity: "FAIL")
        )
        expect(result.diffs.inspect.bytesize).to be < 1_024
      end
    end

    it "does not retain an invalid case ID in a malformed comparison result" do
      case_data = deep_dup(load_legacy_case)
      sensitive_case_id = "secret\nprivate-receipt-evidence"
      case_data["case_id"] = sensitive_case_id

      result = bounded_call { described_class.call(case_data, {}) }

      aggregate_failures do
        expect(result.status).to eq("FAIL")
        expect(result.case_id).to be_nil
        expect(result.inspect).not_to include(sensitive_case_id, "private-receipt-evidence")
      end
    end

    it "treats malformed candidate entries as unexpected instead of candidate absence" do
      case_data = deep_dup(load_legacy_case)
      case_data["expected"]["reference_pricing_candidates"] = [
        { "item_index" => 0, "validation_state" => "none", "rejection_reasons" => [] }
      ]
      actual = GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data)
      actual["reference_pricing_candidates"] = [ nil, "candidate", 1 ]

      result = bounded_call { described_class.call(case_data, actual) }

      aggregate_failures do
        expect(result.status).to eq("FAIL")
        expect(result.diffs).to include(
          satisfy do |diff|
            %w[comparison_input reference_pricing_candidates].include?(diff[:path]) &&
              diff[:severity] == "FAIL"
          end
        )
        expect(
          described_class.reference_pricing_candidates_summary(
            actual["reference_pricing_candidates"]
          )
        ).to all(include("validation_state" => "malformed"))
      end
    end

    it "does not accept a candidate object where the candidate array is required" do
      case_data = deep_dup(load_legacy_case)
      case_data["expected"]["reference_pricing_candidates"] = [
        { "item_index" => 0, "validation_state" => "none", "rejection_reasons" => [] }
      ]
      actual = GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data)
      actual["reference_pricing_candidates"] = {
        "item_index" => 0,
        "validation_state" => "valid",
        "rejection_reasons" => []
      }

      expect(bounded_call { described_class.call(case_data, actual) }.status).to eq("FAIL")
    end

    it "fails closed for malformed actual snapshot shapes" do
      case_data = load_legacy_case

      aggregate_failures do
        [ nil, [], "snapshot", { "items" => [ nil ] } ].each do |actual|
          result = bounded_call { described_class.call(case_data, actual) }

          expect(result.status).to eq("FAIL")
          expect(result.diffs).to contain_exactly(
            hash_including(path: "comparison_input", severity: "FAIL")
          )
        end
      end
    end

    it "accepts at most 100 entries in every compared actual collection" do
      case_data = load_legacy_case
      base_actual = GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data)
      entries = {
        "items" => base_actual.fetch("items").first,
        "tax_details" => base_actual.fetch("tax_details").first,
        "receipt_adjustments" => {
          "kind" => "other",
          "label" => "sample",
          "sign" => "surcharge",
          "amount" => 1,
          "effect" => "purchase",
          "tax_rate" => "0.1",
          "review_reasons" => []
        },
        "payments" => base_actual.fetch("payments").first,
        "review_reasons" => "item_name_uncertain",
        "reference_pricing_candidates" => {
          "item_index" => 0,
          "validation_state" => "unsupported",
          "rejection_reasons" => [ "unsupported_reference_unit" ]
        }
      }

      aggregate_failures do
        entries.each do |key, entry|
          at_limit = deep_dup(base_actual)
          at_limit[key] = Array.new(100) { deep_dup(entry) }
          at_limit_result = bounded_call { described_class.call(case_data, at_limit) }

          expect(at_limit_result.diffs).not_to include(
            hash_including(path: "comparison_input")
          ), "#{key} at limit"

          over_limit = deep_dup(base_actual)
          over_limit[key] = Array.new(101) { deep_dup(entry) }
          over_limit_result = bounded_call { described_class.call(case_data, over_limit) }

          expect(over_limit_result.diffs).to contain_exactly(
            hash_including(path: "comparison_input", severity: "FAIL")
          ), "#{key} over limit"
        end
      end
    end

    it "rejects 100,000 actual items before mapping or retaining a large diff" do
      case_data = load_legacy_case
      actual = GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data)
      actual["items"] = Array.new(100_000, actual.fetch("items").first)

      result = bounded_call { described_class.call(case_data, actual) }

      aggregate_failures do
        expect(result.status).to eq("FAIL")
        expect(result.diffs).to contain_exactly(
          hash_including(path: "comparison_input", severity: "FAIL")
        )
        expect(result.diffs.inspect.bytesize).to be < 1_024
      end
    end

    it "rejects malformed nested actual collection values without exposing them" do
      case_data = load_legacy_case
      sensitive_marker = "private-receipt-evidence"
      mutations = {
        "non-object entry" => ->(actual) { actual["items"][0] = nil },
        "oversized child hash" => lambda do |actual|
          actual["items"][0]["ignored"] = 65.times.to_h { |index| [ "k#{index}", index ] }
        end,
        "oversized nested array" => lambda do |actual|
          actual["items"][0]["ignored"] = Array.new(101, "x")
        end,
        "oversized nested string" => lambda do |actual|
          actual["items"][0]["ignored"] = sensitive_marker + ("x" * 513)
        end,
        "invalid encoding" => ->(actual) { actual["items"][0]["name"] = "\xFF".b },
        "control character" => ->(actual) { actual["items"][0]["name"] = "item\u0000name" },
        "malformed adjustment reasons" => lambda do |actual|
          actual["receipt_adjustments"] = [
            { "review_reasons" => Array.new(101, "adjustment_uncertain") }
          ]
        end
      }

      aggregate_failures do
        mutations.each do |label, mutate|
          actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
          mutate.call(actual)

          result = bounded_call { described_class.call(case_data, actual) }

          expect(result.diffs).to contain_exactly(
            hash_including(path: "comparison_input", severity: "FAIL")
          ), label
          expect(result.diffs.inspect).not_to include(sensitive_marker), label
          expect(result.diffs.inspect.bytesize).to be < 1_024, label
        end
      end
    end

    it "rejects unknown actual snapshot fields without retaining raw evidence" do
      case_data = load_legacy_case
      sensitive_marker = "private-receipt-evidence"
      mutations = {
        "root" => lambda do |actual|
          actual["raw_provider_response"] = sensitive_marker + ("x" * 100_000)
        end,
        "item" => lambda do |actual|
          actual["items"][0]["raw_provider_response"] = sensitive_marker
        end,
        "tax detail" => lambda do |actual|
          actual["tax_details"][0]["raw_provider_response"] = sensitive_marker
        end,
        "adjustment" => lambda do |actual|
          actual["receipt_adjustments"] = [
            { "raw_provider_response" => sensitive_marker }
          ]
        end,
        "payment" => lambda do |actual|
          actual["payments"][0]["raw_provider_response"] = sensitive_marker
        end
      }

      aggregate_failures do
        mutations.each do |label, mutate|
          actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
          mutate.call(actual)

          result = bounded_call { described_class.call(case_data, actual) }

          expect(result.diffs).to contain_exactly(
            hash_including(path: "comparison_input", severity: "FAIL")
          ), label
          expect(result.inspect).not_to include(sensitive_marker), label
          expect(result.inspect.bytesize).to be < 1_024, label
        end
      end
    end

    it "bounds known collections even when a non-receipt comparison ignores their values" do
      case_data = GeneratedReceipts::Validator.load_file(
        File.join(GeneratedReceipts::CASES_DIR, "g081_non_receipt_memo.json")
      )
      sensitive_marker = "private-receipt-evidence"

      aggregate_failures do
        %w[items tax_details receipt_adjustments payments reference_pricing_candidates].each do |key|
          actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
          actual[key] = sensitive_marker + ("x" * 100_000)

          result = bounded_call { described_class.call(case_data, actual) }

          expect(result.diffs).to contain_exactly(
            hash_including(path: "comparison_input", severity: "FAIL")
          ), key
          expect(result.inspect).not_to include(sensitive_marker), key
        end
      end
    end

    it "fails closed for invalid encoding and forbidden control characters in actual labels" do
      case_data = load_legacy_case

      aggregate_failures do
        [ "\xFF".b, "item\tname", "item\u0000name", "item\u0085name" ].each do |name|
          actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
          actual["items"][0]["name"] = name

          result = bounded_call { described_class.call(case_data, actual) }

          expect(result.status).to eq("FAIL")
          expect(result.diffs).to contain_exactly(
            hash_including(path: "comparison_input", severity: "FAIL")
          )
        end
      end
    end

    it "preserves the bounded multiline item-name contract" do
      case_data = GeneratedReceipts::Validator.load_file(
        File.join(GeneratedReceipts::CASES_DIR, "g020_normal_multiline_item_name.json")
      )
      actual = GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data)

      expect(bounded_call { described_class.call(case_data, actual) }.status).to eq("PASS")
    end

    it "drops out-of-contract decimal components without materializing huge values" do
      huge_rational = Rational(1 << 100_000, 1)
      candidates = [
        {
          item_index: 0,
          validation_state: "unsupported",
          rejection_reasons: [ "reference_price_out_of_bounds" ],
          reference_price_amount: "9" * 63,
          reference_quantity: "10000",
          purchased_quantity: BigDecimal("1E100000")
        },
        {
          item_index: 1,
          validation_state: "unsupported",
          rejection_reasons: [ "invalid_reference_price" ],
          reference_price_amount: huge_rational
        }
      ]

      summaries = bounded_call do
        described_class.reference_pricing_candidates_summary(candidates)
      end

      aggregate_failures do
        expect(summaries.size).to eq(2)
        expect(summaries).to all(satisfy { |entry| !entry.key?("reference_price_amount") })
        expect(summaries.first).not_to include("reference_quantity", "purchased_quantity")
      end
    end

    it "checks candidate token byte limits before encoding scans" do
      oversized_string_class = Class.new(String) do
        def valid_encoding?
          raise "valid_encoding? must not inspect an oversized candidate token"
        end
      end
      oversized = oversized_string_class.new("9" * 65)
      candidates = [
        {
          item_index: 0,
          validation_state: oversized,
          rejection_reasons: []
        }
      ]

      expect do
        expect(
          described_class.reference_pricing_candidates_summary(candidates)
        ).to eq([ described_class::MALFORMED_CANDIDATE_SUMMARY ])
      end.not_to raise_error
    end

    it "rejects an oversized candidate collection instead of truncating it" do
      candidates = Array.new(10_000) do |index|
        {
          item_index: index,
          validation_state: "ambiguous",
          rejection_reasons: Array.new(100, "ambiguous_reference_expression")
        }
      end

      summaries = bounded_call do
        described_class.reference_pricing_candidates_summary(candidates)
      end

      aggregate_failures do
        expect(summaries).to eq([ described_class::MALFORMED_CANDIDATE_SUMMARY ])
        expect(JSON.generate(summaries).bytesize).to be < 256
      end
    end

    it "marks malformed required and exact candidate fields instead of normalizing them away" do
      mutations = {
        "Float reference price" => lambda do |candidate|
          amount = candidate.delete("reference_price_amount").to_f
          candidate["reference_price"] = { "amount" => amount }
        end,
        "Integer reference price" => ->(candidate) { candidate["reference_price_amount"] = 120 },
        "string item index" => lambda do |candidate|
          candidate["item_index"] = candidate["item_index"].to_s
        end,
        "missing item index" => ->(candidate) { candidate.delete("item_index") },
        "Symbol validation state" => ->(candidate) { candidate["validation_state"] = :valid },
        "missing validation state" => ->(candidate) { candidate.delete("validation_state") },
        "non-String rejection reason" => ->(candidate) { candidate["rejection_reasons"] = [ 123 ] },
        "missing rejection reasons" => ->(candidate) { candidate.delete("rejection_reasons") },
        "Symbol unit" => ->(candidate) { candidate["reference_unit_code"] = :milliliter },
        "Integer nested quantity" => lambda do |candidate|
          candidate.delete("reference_quantity")
          candidate["reference_quantity"] = { "amount" => 500, "unit_code" => "milliliter" }
        end,
        "malformed nested quantity" => ->(candidate) { candidate["reference_quantity"] = [] },
        "Symbol tax inclusion" => ->(candidate) { candidate["reference_price_tax_inclusion"] = :gross },
        "String projected total" => ->(candidate) { candidate["projected_line_total"] = "360" },
        "Integer printed total" => ->(candidate) { candidate["printed_line_total"] = 360 }
      }

      aggregate_failures do
        mutations.each do |label, mutate|
          case_data = load_measurement_case("g116_reference_per_500ml")
          actual = deep_dup(
            GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data)
          )
          mutate.call(actual["reference_pricing_candidates"][0])

          summaries = bounded_call do
            described_class.reference_pricing_candidates_summary(
              actual["reference_pricing_candidates"]
            )
          end

          result = bounded_call { described_class.call(case_data, actual) }

          expect(summaries).to eq(
            [ described_class::MALFORMED_CANDIDATE_SUMMARY ]
          ), label
          expect(result.status).to eq("FAIL"), label
          expect(result.diffs).to include(
            satisfy do |diff|
              %w[comparison_input reference_pricing_candidates].include?(diff[:path]) &&
                diff[:severity] == "FAIL"
            end
          ), label
        end
      end
    end

    it "does not truncate or deduplicate candidate reasons and rounding evidence into a pass" do
      cases = {
        "duplicate rejection reasons" => lambda do |case_data, candidate|
          expected_candidate = case_data.dig("expected", "reference_pricing_candidates", 0)
          expected_candidate["validation_state"] = "unsupported"
          expected_candidate["rejection_reasons"] = [ "unsupported_reference_unit" ]
          candidate["validation_state"] = "unsupported"
          candidate["rejection_reasons"] = Array.new(2, "unsupported_reference_unit")
        end,
        "too many rejection reasons" => lambda do |_case_data, candidate|
          reasons = 9.times.map { |index| "reason_#{index}" }
          candidate["validation_state"] = "ambiguous"
          candidate["rejection_reasons"] = reasons
        end,
        "duplicate rounding evidence" => lambda do |_case_data, candidate|
          candidate["rounding_matches"] = [ "floor", "floor" ]
        end,
        "too much rounding evidence" => lambda do |_case_data, candidate|
          candidate["rounding_matches"] = %w[floor half_up ceil floor]
        end,
        "non-String rounding evidence" => lambda do |_case_data, candidate|
          candidate["rounding_matches"] = [ 123 ]
        end
      }

      aggregate_failures do
        cases.each do |label, mutate|
          case_data = deep_dup(load_measurement_case("g122_printed_total_mismatch"))
          actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
          mutate.call(case_data, actual.dig("reference_pricing_candidates", 0))

          summaries = bounded_call do
            described_class.reference_pricing_candidates_summary(
              actual["reference_pricing_candidates"]
            )
          end
          result = bounded_call { described_class.call(case_data, actual) }

          expect(summaries).to eq(
            [ described_class::MALFORMED_CANDIDATE_SUMMARY ]
          ), label
          expect(result.status).to eq("FAIL"), label
          expect(result.diffs).to include(
            hash_including(path: "reference_pricing_candidates", severity: "FAIL")
          ), label
        end
      end
    end

    it "rejects scientific notation without materializing an expanded diff" do
      case_data = load_legacy_case
      actual = deep_dup(
        GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data)
      )
      actual["items"][0]["quantity"] = "1e100000"

      result = bounded_call { described_class.call(case_data, actual) }

      aggregate_failures do
        expect(result.status).to eq("FAIL")
        expect(result.diffs).to include(
          hash_including(path: "item_amounts", severity: "FAIL")
        )
        expect(result.diffs.inspect.bytesize).to be < 4_096
      end
    end
  end

  describe GeneratedReceipts::ComparisonRunner do
    it "accepts only one or two Integer executions" do
      aggregate_failures do
        expect(described_class::MAX_RUNS).to eq(2)
        expect(described_class.valid_runs?(1)).to be(true)
        expect(described_class.valid_runs?(2)).to be(true)
        [ 0, -1, 3, "1", 1.0, 1 << 100_000 ].each do |value|
          expect(bounded_call { described_class.valid_runs?(value) }).to be(false), value.class.name
        end
      end
    end

    it "rejects an invalid execution count before the pipeline can run" do
      case_data = load_legacy_case
      allow(GeneratedReceipts::PipelineRunner).to receive(:call)

      aggregate_failures do
        [ 0, -1, 3, "1", 1.0, 1 << 100_000 ].each do |runs|
          expect do
            bounded_call do
              described_class.new(
                case_data,
                image_path: "/tmp/generated.png",
                user: instance_double("User"),
                runs: runs
              )
            end
          end.to raise_error(
            ArgumentError,
            described_class::INVALID_RUNS_MESSAGE
          ), runs.class.name
        end
        expect(GeneratedReceipts::PipelineRunner).not_to have_received(:call)
      end
    end

    it "does not classify an empty synthetic run result as PASS or stable" do
      result = described_class::Result.new(case_id: "g000_sample", run_results: [])

      aggregate_failures do
        expect(result.status).to eq("FAIL")
        expect(result).not_to be_stable
      end
    end

    it "fails closed for malformed synthetic run results" do
      shared_nested_value = "x"
      3.times { shared_nested_value = Array.new(100, shared_nested_value) }
      malformed = [
        nil,
        [ nil ],
        [ {} ],
        [ { status: [] } ],
        [ { status: "PASS", diffs: nil } ],
        [ { status: "PASS", diffs: [ "diff" ] } ],
        [ { status: "PASS", diffs: [ [ "diff" ] ] } ],
        [ { status: "PASS", diffs: [ 1 ] } ],
        [ { status: "PASS", diffs: [ nil ] } ],
        [ { status: "PASS", diffs: [ { ("k" * 65) => "value" } ] } ],
        [ { status: "PASS", diffs: [ { path: "bad\u0000value" } ] } ],
        [ { status: "WARN", diffs: [ { path: "x", expected: nil, actual: shared_nested_value, severity: "WARN" } ] } ],
        [ { status: "PASS", diffs: [ {} ] } ],
        [ { status: "PASS", diffs: [ { path: "x", expected: nil, actual: nil, severity: "FAIL" } ] } ],
        [ { status: "WARN", diffs: [] } ],
        [ { status: "WARN", diffs: [ { path: "x", expected: "a", actual: "b", severity: "FAIL" } ] } ],
        [ { status: "WARN", diffs: [ { path: "x\nforged", expected: "a", actual: "b", severity: "WARN" } ] } ],
        [ { status: "FAIL", diffs: [ { path: "x", expected: "a", actual: "b", severity: "WARN" } ] } ],
        [
          {
            status: "WARN",
            diffs: [ { "path" => "x", path: "y", expected: "a", actual: "b", severity: "WARN" } ]
          }
        ],
        [ { status: "PASS", diffs: Array.new(101, {}) } ],
        [ { status: "PASS", diffs: [ { path: "x", actual: "x" * 513 } ] } ],
        Array.new(3) { { status: "PASS", diffs: [] } }
      ]

      aggregate_failures do
        malformed.each_with_index do |run_results, index|
          result = described_class::Result.new(case_id: "g000_sample", run_results: run_results)

          expect { result.status }.not_to raise_error, "variant #{index}"
          expect { result.stable? }.not_to raise_error, "variant #{index}"
          expect(result.status).to eq("FAIL"), "variant #{index}"
          expect(result).not_to be_stable, "variant #{index}"
        end
      end
    end

    it "fails closed for malformed synthetic result case IDs" do
      run_results = [ { status: "PASS", diffs: [] } ]

      aggregate_failures do
        [ nil, 1, "", "sample", "g000_forged\nline", "g000_#{'x' * 100_000}" ].each_with_index do |case_id, index|
          result = described_class::Result.new(case_id: case_id, run_results: run_results)

          expect { result.status }.not_to raise_error, "variant #{index}"
          expect { result.stable? }.not_to raise_error, "variant #{index}"
          expect(result.status).to eq("FAIL"), "variant #{index}"
          expect(result).not_to be_stable, "variant #{index}"
        end
      end
    end

    it "rejects comparison results that are shadowed or associated with another case" do
      comparison = GeneratedReceipts::Comparator::Result.new(
        case_id: "g000_sample",
        status: "FAIL",
        diffs: [
          { path: "total", expected: 100, actual: 99, severity: "FAIL" }
        ]
      )
      variants = [
        {
          status: "PASS",
          diffs: [],
          comparison: comparison
        },
        {
          status: "FAIL",
          diffs: comparison.diffs,
          comparison: comparison.dup.tap { |result| result.case_id = "g001_other" }
        }
      ]

      aggregate_failures do
        variants.each_with_index do |run, index|
          result = described_class::Result.new(
            case_id: "g000_sample",
            run_results: [ run ]
          )

          expect(result.status).to eq("FAIL"), "variant #{index}"
          expect(result).not_to be_stable, "variant #{index}"
        end
      end
    end

    it "loads and evaluates a bounded synthetic result without the full tooling registry" do
      runner_path = File.expand_path(
        "../../../tools/generated_receipts/comparison_runner",
        GeneratedReceipts::ROOT
      )
      script = <<~RUBY
        require #{runner_path.inspect}
        result = GeneratedReceipts::ComparisonRunner::Result.new(
          case_id: "g000_sample",
          run_results: [ { status: "PASS", diffs: [] } ]
        )
        print "\#{result.status}:\#{result.stable?}"
      RUBY

      stdout, stderr, status = bounded_call { Open3.capture3(RbConfig.ruby, "-e", script) }

      aggregate_failures do
        expect(status).to be_success
        expect(stderr).to eq("")
        expect(stdout).to eq("PASS:true")
      end
    end

    it "has the compare CLI reject unsafe run tokens before the execute gate" do
      command = File.join(GeneratedReceipts::ROOT, "../../../bin/generated_receipts_compare")

      aggregate_failures do
        [ "0", "-1", "3", "1.0", "9" * 1_000 ].each do |runs|
          _stdout, stderr, status = bounded_call do
            Open3.capture3(RbConfig.ruby, command, "--runs", runs)
          end

          label = "#{runs.bytesize} byte run token"
          expect(status.exitstatus).to eq(1), label
          expect(stderr).to eq("#{described_class::INVALID_RUNS_MESSAGE}\n"), label
          expect(stderr.bytesize).to be < 128, label
        end
      end
    end
  end
end
