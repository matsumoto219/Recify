# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Receipt form Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/receipt_form_controller.js").read }

  def run_controller_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class ReceiptFormController extends Controller')

      eval(`${source}\nglobalThis.ReceiptFormController = ReceiptFormController`)
      #{script}
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
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
