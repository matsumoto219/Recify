# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Receipt form Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/receipt_form_controller.js").read }

  def run_controller_script(script)
    module_source = %w[numeric_input amount_preview review_targets].map do |name|
      Rails.root.join("app/javascript/receipts/#{name}.js").read.gsub(/^export /, "")
    end.join("\n")
    controller_source = source.gsub(%r!import \{[^}]*\} from 'receipts/(?:numeric_input|amount_preview|review_targets)'\n!m, "")
    encoded_module_source = Base64.strict_encode64(module_source)
    encoded_source = Base64.strict_encode64(controller_source)
    harness = <<~JAVASCRIPT
      const moduleSource = Buffer.from(#{encoded_module_source.inspect}, 'base64').toString('utf8')
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class ReceiptFormController extends Controller')

      eval(`${moduleSource}\n${source}\nglobalThis.ReceiptFormController = ReceiptFormController`)
      #{script}
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  def run_amount_round_trip(basis:, items:, adjustments: [])
    run_controller_script(<<~JAVASCRIPT)
      const itemDefinitions = #{items.to_json}
      const adjustmentDefinitions = #{adjustments.to_json}
      const amountTarget = () => ({ value: null, textContent: '', title: '', dataset: {} })
      const rows = itemDefinitions.map((definition) => {
        const inputs = {
          quantityInput: { value: '1' },
          quantityUnitInput: { value: 'each' },
          priceInput: { value: String(definition.price) },
          discountRateInput: { value: '', dataset: { originalDiscountRate: '' } },
          taxRateInput: { value: String(definition.taxRate) },
          lineTotalInput: {
            value: String(definition.lineTotal),
            dataset: {
              originalLineTotal: String(definition.lineTotal),
              originalSavedLineTotal: String(definition.lineTotal)
            }
          }
        }

        return {
          inputs,
          querySelector (selector) {
            const match = selector.match(/receipt-form-target="([^"]+)"/)
            return match ? inputs[match[1]] : null
          },
          querySelectorAll () { return [] }
        }
      })
      const controller = Object.create(ReceiptFormController.prototype)
      const adjustmentRows = adjustmentDefinitions.map((definition) => {
        const inputs = {
          adjustmentAmountInput: { value: String(definition.amount) },
          adjustmentTaxRateInput: { value: String(definition.taxRate) }
        }

        return {
          definition,
          querySelector (selector) {
            const match = selector.match(/receipt-form-target="([^"]+)"/)
            return match ? inputs[match[1]] : null
          }
        }
      })
      const subtotal = amountTarget()
      const tax = amountTarget()
      const total = amountTarget()
      let paymentAdjustmentSnapshot = null

      Object.defineProperties(controller, {
        itemRowTargets: { value: rows },
        adjustmentRowTargets: { value: adjustmentRows },
        paymentRowTargets: { value: [] },
        receiptTaxBasisValue: { value: #{basis.to_json} },
        roundingModeValue: { value: 'floor' },
        discountRoundingModeValue: { value: 'round' },
        countableQuantityUnitsValue: { value: 'each,piece,item,bottle,bag,box' },
        receiptItemPriceMaxValue: { value: 999999999 },
        receiptItemLineTotalMaxValue: { value: 999999999 },
        receiptAdjustmentAmountMaxValue: { value: 999999999 },
        receiptPaymentAmountMaxValue: { value: 999999999 },
        receiptTotalAmountMaxValue: { value: 999999999 },
        receiptTaxAmountMaxValue: { value: 999999999 },
        hasTotalAmountTarget: { value: true },
        totalAmountTarget: { value: total },
        hasSubtotalAmountTarget: { value: true },
        subtotalAmountTarget: { value: subtotal },
        hasTaxAmountTarget: { value: true },
        taxAmountTarget: { value: tax },
        hasTaxRateSummaryTarget: { value: false }
      })

      controller.previewNumericInputsValid = () => true
      controller.previewRowExcluded = () => false
      controller.animateAmount = (target, value) => { target.value = value }
      controller.animateLineTotal = () => {}
      controller.syncAdjustmentSignForRow = () => {}
      controller.adjustmentEffectForRow = (row) => row.definition.effect
      controller.adjustmentSignForRow = (row) => row.definition.sign
      controller.syncPaymentAdjustmentSummary = (adjustmentTotal, finalPaymentTotal) => {
        paymentAdjustmentSnapshot = { adjustmentTotal, finalPaymentTotal }
      }
      controller.syncPaymentReconciliationSummary = () => {}
      controller.paymentAmountSum = () => 801

      const snapshot = () => {
        const amounts = {
          subtotal: subtotal.value,
          tax: tax.value,
          total: total.value,
          firstLineTotal: Number(rows[0].inputs.lineTotalInput.value)
        }

        if (adjustmentDefinitions.length > 0) {
          amounts.paymentAdjustmentTotal = paymentAdjustmentSnapshot.adjustmentTotal
          amounts.finalPaymentTotal = paymentAdjustmentSnapshot.finalPaymentTotal
        }

        return amounts
      }

      controller.recalculate()
      const initial = snapshot()
      rows[0].inputs.quantityInput.value = '2'
      controller.recalculate()
      const doubled = snapshot()
      rows[0].inputs.quantityInput.value = '1'
      controller.recalculate()
      const restored = snapshot()

      process.stdout.write(JSON.stringify({ initial, doubled, restored }))
    JAVASCRIPT
  end

  it "opens item detail panels from item review target hashes without toggling them closed" do
    aggregate_failures do
      expect(source).to include("reviewItemTargetPrefix: String")
      expect(source).to include("reviewItemsTarget: String")
      expect(source).to include("window.addEventListener('hashchange', this.handleHashChange)")
      expect(source).to include("this.expandItemDetailsFromHash()")
      expect(source).to include("setItemDetailsOpen({ row, panel, toggles, icons, open: true })")
      expect(source).to include("this.pushReviewTargetHash(targetId)")
      expect(source).to include("targetId.startsWith(this.reviewItemTargetPrefixValue)")
      expect(source).not_to include("REVIEW_REASON_ITEM_TARGET_PREFIX = 'receipt-item-'")
    end
  end

  it "falls back safely when the target item row is missing or already deleted" do
    aggregate_failures do
      expect(source).to include("if (!this.reviewItemRowVisible(row))")
      expect(source).to include("destroyField?.value !== '1'")
      expect(source).to include("this.scrollReviewTargetFallback()")
      expect(source).to include("const fallback = document.getElementById(targetId) || document.getElementById(this.reviewItemsTargetValue)")
      expect(source).not_to include("RECEIPT_REVIEW_TARGET_ITEMS = 'receipt-section-items'")
    end
  end

  it "keeps the latest countable line total as the baseline for repeated recalculation" do
    aggregate_failures do
      expect(source).to include("lineTotalInput.dataset.originalLineTotal = String(originalLineTotal)")
      expect(source).to include("lineTotalInput.dataset.originalSavedLineTotal = String(lineTotal)")
      expect(source).to include("if (this.recalculatesQuantityUnit(quantityUnit))")
    end
  end

  it "does not rewrite a quantity while the administrator is typing" do
    aggregate_failures do
      expect(source).not_to include("sanitizeQuantityInput")
      expect(source).not_to include("preventIntegerQuantityDecimalInput")
    end
  end

  it "does not parse malformed user input as another preview amount" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(ReceiptFormController.prototype)
      const invalidIntegers = ['1e2', 'abc12', '12abc', 'abc', '-100', '1.5', '¥100']
      const invalidDecimals = ['1e2', 'abc12', '12abc', 'abc', '-0.5', '1.2.3', '10percent']
      const serialize = (value) => ({ valid: Number.isFinite(value), value })

      process.stdout.write(JSON.stringify({
        invalidIntegers: invalidIntegers.map((value) => serialize(controller.parseIntegerInput(value))),
        invalidDecimals: invalidDecimals.map((value) => serialize(controller.parseDecimalInput(value))),
        validIntegers: ['100', '1,000', '001', '１００'].map((value) => serialize(controller.parseIntegerInput(value))),
        validDecimals: ['1.5', '.5', '1.', '０．５'].map((value) => serialize(controller.parseDecimalInput(value)))
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["invalidIntegers"]).to all(include("valid" => false))
      expect(result["invalidDecimals"]).to all(include("valid" => false))
      expect(result["validIntegers"]).to all(include("valid" => true))
      expect(result["validIntegers"].map { |entry| entry["value"] }).to eq([ 100, 1_000, 1, 100 ])
      expect(result["validDecimals"]).to all(include("valid" => true))
      expect(result["validDecimals"].map { |entry| entry["value"] }).to eq([ 1.5, 0.5, 1, 0.5 ])
    end
  end

  it "passes receipt rounding modes and labels to the pure amount preview helpers" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(ReceiptFormController.prototype)
      Object.defineProperties(controller, {
        roundingModeValue: { value: 'ceil' },
        discountRoundingModeValue: { value: 'floor' },
        unsetLabelValue: { value: 'Unset' },
        multipleTaxRatesLabelValue: { value: 'Multiple tax rates' }
      })

      process.stdout.write(JSON.stringify({
        externalTax: controller.externalTaxTotal(new Map([[8, 101], [10, 105]])),
        discountedLineTotal: controller.discountedLineTotalFor(101, 50),
        signedAmount: controller.formatSignedAmount(-500),
        zeroDifference: controller.formatPaymentDifference(0),
        noTaxRate: controller.formatTaxRateSummary(new Set()),
        multipleTaxRates: controller.formatTaxRateSummary(new Set([8, 10]))
      }))
    JAVASCRIPT

    expect(result).to eq(
      "externalTax" => 20,
      "discountedLineTotal" => 51,
      "signedAmount" => "-¥500",
      "zeroDifference" => "¥0",
      "noTaxRate" => "Unset",
      "multipleTaxRates" => "Multiple tax rates"
    )
  end

  it "recalculates the external net receipt from quantity 1 to 2 and back without drift" do
    result = run_amount_round_trip(
      basis: 'external',
      items: [
        { price: 128, lineTotal: 128, taxRate: 8 },
        { price: 198, lineTotal: 198, taxRate: 8 },
        { price: 115, lineTotal: 115, taxRate: 8 },
        { price: 298, lineTotal: 298, taxRate: 8 },
        { price: 3, lineTotal: 3, taxRate: 10 }
      ]
    )

    expect(result).to eq(
      'initial' => { 'subtotal' => 742, 'tax' => 59, 'total' => 801, 'firstLineTotal' => 128 },
      'doubled' => { 'subtotal' => 870, 'tax' => 69, 'total' => 939, 'firstLineTotal' => 256 },
      'restored' => { 'subtotal' => 742, 'tax' => 59, 'total' => 801, 'firstLineTotal' => 128 }
    )
  end

  it "rounds internal tax once per tax-rate group like the Amount Engine" do
    result = run_amount_round_trip(
      basis: 'internal',
      items: [
        { price: 138, lineTotal: 138, taxRate: 8 },
        { price: 213, lineTotal: 213, taxRate: 8 },
        { price: 124, lineTotal: 124, taxRate: 8 },
        { price: 321, lineTotal: 321, taxRate: 8 },
        { price: 3, lineTotal: 3, taxRate: 10 }
      ]
    )

    expect(result).to eq(
      'initial' => { 'subtotal' => 741, 'tax' => 58, 'total' => 799, 'firstLineTotal' => 138 },
      'doubled' => { 'subtotal' => 868, 'tax' => 69, 'total' => 937, 'firstLineTotal' => 276 },
      'restored' => { 'subtotal' => 741, 'tax' => 58, 'total' => 799, 'firstLineTotal' => 138 }
    )
  end

  it "groups purchase adjustments with items but keeps payment and zero-tax adjustments separate" do
    adjustments = [
      { amount: 15, taxRate: 8, effect: "purchase_adjustment", sign: "surcharge" },
      { amount: 5, taxRate: 8, effect: "payment_adjustment", sign: "discount" },
      { amount: 3, taxRate: 0, effect: "purchase_adjustment", sign: "surcharge" }
    ]
    items = [
      { price: 101, lineTotal: 101, taxRate: 8 },
      { price: 100, lineTotal: 100, taxRate: 8 }
    ]

    internal = run_amount_round_trip(basis: "internal", items:, adjustments:)
    external = run_amount_round_trip(basis: "external", items:, adjustments:)

    aggregate_failures do
      expect(internal["initial"]).to eq(
        "subtotal" => 203,
        "tax" => 16,
        "total" => 219,
        "firstLineTotal" => 101,
        "paymentAdjustmentTotal" => -5,
        "finalPaymentTotal" => 214
      )
      expect(external["initial"]).to eq(
        "subtotal" => 219,
        "tax" => 17,
        "total" => 236,
        "firstLineTotal" => 101,
        "paymentAdjustmentTotal" => -5,
        "finalPaymentTotal" => 231
      )
    end
  end

  it "suspends and restores the preview without rewriting an invalid field" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(ReceiptFormController.prototype)
      const quantity = { value: '1' }
      const unit = { value: 'each' }
      const price = { value: 'abc12' }
      const discountRate = { value: '' }
      const taxRate = { value: '10' }
      const inputs = {
        quantityInput: quantity,
        quantityUnitInput: unit,
        priceInput: price,
        discountRateInput: discountRate,
        taxRateInput: taxRate
      }
      const row = {
        style: { display: '' },
        querySelector: (selector) => {
          const match = selector.match(/receipt-form-target="([^"]+)"/)
          return match ? inputs[match[1]] : null
        }
      }
      Object.defineProperties(controller, {
        itemRowTargets: { value: [row] },
        adjustmentRowTargets: { value: [] },
        paymentRowTargets: { value: [] },
        decimalQuantityUnitsValue: { value: 'gram,kilogram' },
        receiptItemPriceMaxValue: { value: 999999999 },
        receiptAdjustmentAmountMaxValue: { value: 999999999 },
        receiptPaymentAmountMaxValue: { value: 999999999 }
      })

      const invalid = controller.previewNumericInputsValid()
      const invalidValue = price.value
      price.value = '100'
      quantity.value = ''
      const emptyQuantity = controller.previewNumericInputsValid()
      const emptyQuantityValue = quantity.value
      quantity.value = '1'
      const valid = controller.previewNumericInputsValid()

      process.stdout.write(JSON.stringify({
        invalid,
        invalidValue,
        emptyQuantity,
        emptyQuantityValue,
        valid,
        validValue: price.value
      }))
    JAVASCRIPT

    expect(result).to eq(
      "invalid" => false,
      "invalidValue" => "abc12",
      "emptyQuantity" => false,
      "emptyQuantityValue" => "",
      "valid" => true,
      "validValue" => "100"
    )
  end

  it "marks a new child row hidden before recalculating its removal" do
    result = run_controller_script(<<~JAVASCRIPT)
      const results = []
      const cases = [
        ['removeItem', 'itemRowForAction', 'itemRowContainer'],
        ['removeAdjustment', 'adjustmentRowForAction', 'adjustmentRowContainer'],
        ['removePayment', 'paymentRowForAction', 'paymentRowContainer']
      ]

      Promise.all(cases.map(async ([method, rowFinder, containerFinder]) => {
        const controller = Object.create(ReceiptFormController.prototype)
        const row = { style: { display: '' }, querySelector: () => null }
        const container = { removed: false, remove () { this.removed = true } }
        const currentTarget = { dataset: {} }
        Object.defineProperty(controller, 'deleteConfirmationEnabledValue', { value: false })
        controller[rowFinder] = () => row
        controller[containerFinder] = () => container
        controller.recalculate = () => results.push({ method, display: row.style.display, removed: container.removed })

        await controller[method]({ preventDefault () {}, currentTarget })
      })).then(() => process.stdout.write(JSON.stringify(results)))
    JAVASCRIPT

    expect(result).to contain_exactly(
      { "method" => "removeItem", "display" => "none", "removed" => true },
      { "method" => "removeAdjustment", "display" => "none", "removed" => true },
      { "method" => "removePayment", "display" => "none", "removed" => true }
    )
  end
end
