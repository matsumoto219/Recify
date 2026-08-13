# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Receipt numeric JavaScript modules" do
  let(:reference_pricing_contract) do
    ReceiptFormPresenter.new(receipt: build(:receipt)).reference_pricing_contract_value
  end

  def run_module_script(name, script)
    source = Rails.root.join("app/javascript/receipts/#{name}.js").read.gsub(/^export /, "")
    encoded_source = Base64.strict_encode64(source)
    encoded_reference_pricing_contract = Base64.strict_encode64(reference_pricing_contract.to_json)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
      const referencePricingContract = JSON.parse(
        Buffer.from(#{encoded_reference_pricing_contract.inspect}, 'base64').toString('utf8')
      )
      eval(`${source}\n#{script}`)
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "strictly parses integer and decimal receipt inputs" do
    result = run_module_script("numeric_input", <<~JAVASCRIPT)
      const serialize = (value) => ({ valid: Number.isFinite(value), value })
      process.stdout.write(JSON.stringify({
        integers: ['100', '1,000', '001', '１００', '1e2', '-1', '¥100'].map((value) => serialize(parseIntegerInput(value))),
        decimals: ['1.5', '.5', '1.', '０．５', '1,5', '1e2', '-0.5'].map((value) => serialize(parseDecimalInput(value))),
        discountBlank: parseDiscountRateInput(''),
        unsafeInteger: serialize(parseIntegerInput('9007199254740992'))
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["integers"].first(4)).to all(include("valid" => true))
      expect(result["integers"].first(4).pluck("value")).to eq([ 100, 1_000, 1, 100 ])
      expect(result["integers"].last(3)).to all(include("valid" => false))
      expect(result["decimals"].first(5).pluck("value")).to eq([ 1.5, 0.5, 1, 0.5, 1.5 ])
      expect(result["decimals"].last(2)).to all(include("valid" => false))
      expect(result["discountBlank"]).to be_nil
      expect(result["unsafeInteger"]).to include("valid" => false)
    end
  end

  it "preserves quantity normalization and preview range rules" do
    result = run_module_script("numeric_input", <<~JAVASCRIPT)
      process.stdout.write(JSON.stringify({
        units: quantityUnitList(' each, kilogram, ,box '),
        normalized: normalizeQuantityText('１２．００'),
        zeroFraction: decimalFractionIsZero('１２．００'),
        integerText: integerQuantityText('１２．００'),
        emptyAllowed: previewValueInRange(null, { minimum: 0, maximum: 10 }),
        zeroExcluded: previewValueInRange(0, { minimum: 0, maximum: 10, exclusiveMinimum: true }),
        maximumAllowed: previewValueInRange(10, { minimum: 0, maximum: 10 })
      }))
    JAVASCRIPT

    expect(result).to eq(
      "units" => %w[each kilogram box],
      "normalized" => "12.00",
      "zeroFraction" => true,
      "integerText" => "12",
      "emptyAllowed" => true,
      "zeroExcluded" => false,
      "maximumAllowed" => true
    )
  end

  it "preserves amount rounding and formatting helpers" do
    result = run_module_script("amount_preview", <<~JAVASCRIPT)
      process.stdout.write(JSON.stringify({
        floor: applyRounding(10.9, 'floor'),
        ceil: applyRounding(10.1, 'ceil'),
        round: applyRounding(10.5, 'round'),
        negativeRound: applyRounding(-10.5, 'round'),
        invalidMode: applyRounding(10.9, 'invalid'),
        clamped: clampNumber(11, 0, 10),
        invalidClamped: clampNumber(Number.NaN, 2, 10),
        lineAmount: roundLineAmount(10.5),
        taxRate: formatTaxRate(8.5),
        eased: easeOutCubic(0.5)
      }))
    JAVASCRIPT

    expect(result).to eq(
      "floor" => 10,
      "ceil" => 11,
      "round" => 11,
      "negativeRound" => -11,
      "invalidMode" => 10,
      "clamped" => 10,
      "invalidClamped" => 2,
      "lineAmount" => 11,
      "taxRate" => "8.5",
      "eased" => 0.875
    )
  end

  it "matches the exact reference price extension and half-up contract" do
    result = run_module_script("amount_preview", <<~JAVASCRIPT)
      const calculate = (overrides = {}) => referenceItemExtension({
        referencePricingContract,
        referencePriceAmount: '120',
        referenceQuantity: '500',
        referenceUnitCode: 'milliliter',
        purchasedQuantity: '1.5',
        purchasedUnitCode: 'liter',
        ...overrides
      })

      process.stdout.write(JSON.stringify({
        volume: calculate(),
        mass: calculate({
          referencePriceAmount: '498',
          referenceQuantity: '100',
          referenceUnitCode: 'gram',
          purchasedQuantity: '342',
          purchasedUnitCode: 'gram'
        }),
        tie: calculate({
          referencePriceAmount: '105',
          referenceQuantity: '100',
          referenceUnitCode: 'gram',
          purchasedQuantity: '10',
          purchasedUnitCode: 'gram'
        }),
        repeating: calculate({
          referencePriceAmount: '100',
          referenceQuantity: '3',
          referenceUnitCode: 'gram',
          purchasedQuantity: '1',
          purchasedUnitCode: 'gram'
        }),
        zero: calculate({ referencePriceAmount: '0' }),
        beforeTie: calculate({
          referencePriceAmount: '0.999998',
          referenceQuantity: '2',
          referenceUnitCode: 'gram',
          purchasedQuantity: '1',
          purchasedUnitCode: 'gram'
        }),
        afterTie: calculate({
          referencePriceAmount: '1.000002',
          referenceQuantity: '2',
          referenceUnitCode: 'gram',
          purchasedQuantity: '1',
          purchasedUnitCode: 'gram'
        })
      }))
    JAVASCRIPT

    expect(result).to eq(
      "volume" => { "exactNumerator" => "360", "exactDenominator" => "1", "projectedAmount" => 360 },
      "mass" => { "exactNumerator" => "42579", "exactDenominator" => "25", "projectedAmount" => 1_703 },
      "tie" => { "exactNumerator" => "21", "exactDenominator" => "2", "projectedAmount" => 11 },
      "repeating" => { "exactNumerator" => "100", "exactDenominator" => "3", "projectedAmount" => 33 },
      "zero" => { "exactNumerator" => "0", "exactDenominator" => "1", "projectedAmount" => 0 },
      "beforeTie" => { "exactNumerator" => "499999", "exactDenominator" => "1000000", "projectedAmount" => 0 },
      "afterTie" => { "exactNumerator" => "500001", "exactDenominator" => "1000000", "projectedAmount" => 1 }
    )
  end

  it "rejects incomplete, incompatible, imprecise, and out-of-range reference sources" do
    result = run_module_script("amount_preview", <<~JAVASCRIPT)
      const calculate = (overrides = {}) => referenceItemExtension({
        referencePricingContract,
        referencePriceAmount: '120',
        referenceQuantity: '500',
        referenceUnitCode: 'milliliter',
        purchasedQuantity: '1.5',
        purchasedUnitCode: 'liter',
        ...overrides
      })
      const inputs = [
        { referencePriceAmount: '' },
        { referencePriceAmount: '1.1234567' },
        { referencePriceAmount: '1000000000000' },
        { referenceQuantity: '0' },
        { referenceQuantity: '1.0001' },
        { referenceQuantity: '10000' },
        { purchasedQuantity: '0.0001' },
        { purchasedQuantity: '10000' },
        { purchasedUnitCode: 'gram' },
        { referenceUnitCode: 'ml' },
        { referenceUnitCode: 'each', purchasedUnitCode: 'box' },
        { referencePriceAmount: '1e2' },
        { referencePriceAmount: '-1' },
        { referencePriceAmount: '+1' }
      ]

      process.stdout.write(JSON.stringify(inputs.map((input) => calculate(input))))
    JAVASCRIPT

    expect(result).to all(be_nil)
  end

  it "enforces the purchased and reference roles supplied by the Ruby unit catalog" do
    result = run_module_script("amount_preview", <<~JAVASCRIPT)
      const calculate = (contract) => referenceItemExtension({
        referencePricingContract: contract,
        referencePriceAmount: '120',
        referenceQuantity: '500',
        referenceUnitCode: 'milliliter',
        purchasedQuantity: '1.5',
        purchasedUnitCode: 'liter'
      })
      const withoutReferenceRole = structuredClone(referencePricingContract)
      withoutReferenceRole.units.milliliter.allowed_pricing_roles = ['purchased']
      const withoutPurchasedRole = structuredClone(referencePricingContract)
      withoutPurchasedRole.units.liter.allowed_pricing_roles = ['reference']

      process.stdout.write(JSON.stringify({
        accepted: calculate(referencePricingContract),
        referenceRejected: calculate(withoutReferenceRole),
        purchasedRejected: calculate(withoutPurchasedRole)
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result.dig("accepted", "projectedAmount")).to eq(360)
      expect(result["referenceRejected"]).to be_nil
      expect(result["purchasedRejected"]).to be_nil
    end
  end

  it "keeps source text unchanged and preserves equivalent reference ratios" do
    result = run_module_script("amount_preview", <<~JAVASCRIPT)
      const source = {
        referencePricingContract,
        referencePriceAmount: '４９８.０',
        referenceQuantity: '１００.０',
        referenceUnitCode: 'gram',
        purchasedQuantity: '３４２.０',
        purchasedUnitCode: 'gram'
      }
      const before = JSON.stringify(source)
      const base = referenceItemExtension(source)
      const scaled = referenceItemExtension({
        ...source,
        referencePriceAmount: '996',
        referenceQuantity: '200'
      })

      process.stdout.write(JSON.stringify({ before, after: JSON.stringify(source), base, scaled }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["after"]).to eq(result["before"])
      expect(result["scaled"]).to eq(result["base"])
      expect(result.dig("base", "projectedAmount")).to eq(1_703)
    end
  end

  it "formats signed amounts, payment differences, and tax rate summaries" do
    result = run_module_script("amount_preview", <<~JAVASCRIPT)
      process.stdout.write(JSON.stringify({
        signedPositive: formatSignedAmount(1234.9),
        signedNegative: formatSignedAmount(-1234.9),
        zeroDifference: formatPaymentDifference(0),
        positiveDifference: formatPaymentDifference(500),
        noTaxRate: formatTaxRateSummary(new Set(), {
          unsetLabel: 'Unset',
          multipleTaxRatesLabel: 'Multiple tax rates'
        }),
        decimalTaxRate: formatTaxRateSummary(new Set([8.5]), {
          unsetLabel: 'Unset',
          multipleTaxRatesLabel: 'Multiple tax rates'
        }),
        multipleTaxRates: formatTaxRateSummary(new Set([8, 10]), {
          unsetLabel: 'Unset',
          multipleTaxRatesLabel: 'Multiple tax rates'
        })
      }))
    JAVASCRIPT

    expect(result).to eq(
      "signedPositive" => "+¥1,234",
      "signedNegative" => "-¥1,234",
      "zeroDifference" => "¥0",
      "positiveDifference" => "+¥500",
      "noTaxRate" => "Unset",
      "decimalTaxRate" => "8.5%",
      "multipleTaxRates" => "Multiple tax rates"
    )
  end

  it "rounds external tax per group and discounts with the configured mode" do
    result = run_module_script("amount_preview", <<~JAVASCRIPT)
      const taxGroups = new Map([[8, 101], [10, 105]])
      const negativeHalfGroup = new Map([[50, -1]])

      process.stdout.write(JSON.stringify({
        externalTaxFloor: externalTaxTotal(taxGroups, 'floor'),
        externalTaxCeil: externalTaxTotal(taxGroups, 'ceil'),
        externalTaxRound: externalTaxTotal(taxGroups, 'round'),
        externalDecimalHalfRound: externalTaxTotal(new Map([[0.7, 5500]]), 'round'),
        externalNegativeHalfRound: externalTaxTotal(negativeHalfGroup, 'round'),
        discountUnset: discountedLineTotal(101, null, 'floor'),
        discountHalfPercent: discountedLineTotal(1000, 0.5, 'round'),
        discountOnePercent: discountedLineTotal(1000, 1, 'round'),
        discountDecimalHalfRound: discountedLineTotal(5500, 0.7, 'round'),
        discountFull: discountedLineTotal(101, 100, 'floor'),
        discountFloor: discountedLineTotal(101, 50, 'floor'),
        discountCeil: discountedLineTotal(101, 50, 'ceil'),
        discountRound: discountedLineTotal(101, 50, 'round')
      }))
    JAVASCRIPT

    expect(result).to eq(
      "externalTaxFloor" => 18,
      "externalTaxCeil" => 20,
      "externalTaxRound" => 19,
      "externalDecimalHalfRound" => 39,
      "externalNegativeHalfRound" => -1,
      "discountUnset" => 101,
      "discountHalfPercent" => 995,
      "discountOnePercent" => 990,
      "discountDecimalHalfRound" => 5461,
      "discountFull" => 0,
      "discountFloor" => 51,
      "discountCeil" => 50,
      "discountRound" => 50
    )
  end

  it "rounds internal tax once per signed tax-rate group" do
    result = run_module_script("amount_preview", <<~JAVASCRIPT)
      const initialGroups = new Map([[8, 796], [10, 3]])
      const doubledGroups = new Map([[8, 934], [10, 3]])
      const adjustedGroup = new Map([[8, 796 - 50]])
      const negativeHalfGroup = new Map([[100, -1]])

      process.stdout.write(JSON.stringify({
        initialFloor: internalTaxTotal(initialGroups, 'floor'),
        doubledFloor: internalTaxTotal(doubledGroups, 'floor'),
        adjustedFloor: internalTaxTotal(adjustedGroup, 'floor'),
        adjustedCeil: internalTaxTotal(adjustedGroup, 'ceil'),
        adjustedRound: internalTaxTotal(adjustedGroup, 'round'),
        decimalExactCeil: internalTaxTotal(new Map([[0.1, 1001]]), 'ceil'),
        negativeHalfRound: internalTaxTotal(negativeHalfGroup, 'round')
      }))
    JAVASCRIPT

    expect(result).to eq(
      "initialFloor" => 58,
      "doubledFloor" => 69,
      "adjustedFloor" => 55,
      "adjustedCeil" => 56,
      "adjustedRound" => 55,
      "decimalExactCeil" => 1,
      "negativeHalfRound" => -1
    )
  end
end
