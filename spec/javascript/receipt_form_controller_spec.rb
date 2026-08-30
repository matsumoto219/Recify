# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Receipt form Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/receipt_form_controller.js").read }
  let(:reference_pricing_contract) do
    ReceiptFormPresenter.new(receipt: build(:receipt)).reference_pricing_contract_value
  end

  def run_controller_script(script)
    module_source = %w[numeric_input amount_preview review_targets].map do |name|
      Rails.root.join("app/javascript/receipts/#{name}.js").read.gsub(/^export /, "")
    end.join("\n")
    controller_source = source.gsub(%r!import \{[^}]*\} from 'receipts/(?:numeric_input|amount_preview|review_targets)'\n!m, "")
    encoded_module_source = Base64.strict_encode64(module_source)
    encoded_source = Base64.strict_encode64(controller_source)
    encoded_reference_pricing_contract = Base64.strict_encode64(reference_pricing_contract.to_json)
    harness = <<~JAVASCRIPT
      const moduleSource = Buffer.from(#{encoded_module_source.inspect}, 'base64').toString('utf8')
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class ReceiptFormController extends Controller')

      eval(`${moduleSource}\n${source}\nglobalThis.ReceiptFormController = ReceiptFormController`)
      const referencePricingContract = JSON.parse(
        Buffer.from(#{encoded_reference_pricing_contract.inspect}, 'base64').toString('utf8')
      )
      Object.defineProperty(ReceiptFormController.prototype, 'referencePricingContractValue', {
        configurable: true,
        get: () => referencePricingContract
      })
      #{script}
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", stdin_data: harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  def run_review_target_script(script)
    run_controller_script(<<~JAVASCRIPT)
      const listeners = {
        document: new Map(),
        element: new Map(),
        window: new Map()
      }
      const location = new URL('https://recify.example/receipts/rcpt_1/edit')
      const rows = []
      const links = []
      let fetchCount = 0

      const classList = (initial = []) => {
        const values = new Set(initial)
        return {
          contains: (name) => values.has(name),
          remove: (...names) => names.forEach((name) => values.delete(name)),
          toggle: (name, force) => {
            const enabled = force === undefined ? !values.has(name) : force
            if (enabled) values.add(name)
            else values.delete(name)
            return enabled
          }
        }
      }

      const makeToggle = ({ visible = true } = {}) => {
        const attributes = new Map()
        return {
          visible,
          hidden: !visible,
          offsetParent: visible ? {} : null,
          focusCount: 0,
          focusOptions: [],
          checkVisibility: () => visible,
          getClientRects: () => visible ? [ {} ] : [],
          getAttribute: (name) => attributes.get(name) ?? null,
          setAttribute: (name, value) => attributes.set(name, String(value)),
          focus (options) {
            this.focusCount += 1
            this.focusOptions.push(options ?? null)
            document.activeElement = this
          }
        }
      }

      const makeRow = ({
        id,
        type,
        open = false,
        destroyed = false,
        inside = true,
        hidden = false,
        reviewTarget = true
      }) => {
        const panelTarget = type === 'item' ? 'itemDetailsPanel' : 'adjustmentDetailsPanel'
        const toggleTarget = type === 'item' ? 'itemDetailsToggle' : 'adjustmentDetailsToggle'
        const iconTarget = type === 'item' ? 'itemDetailsIcon' : 'adjustmentDetailsIcon'
        const destroyTarget = type === 'item' ? 'destroyField' : 'adjustmentDestroyField'
        const openClass = type === 'item' ? 'receipt-form-item-details-open' : 'receipt-form-adjustment-details-open'
        const panelAttributes = new Map([ [ 'aria-hidden', String(!open) ] ])
        const panel = {
          classList: classList(open ? [ 'is-open' ] : []),
          inert: !open,
          getAttribute: (name) => panelAttributes.get(name) ?? null,
          setAttribute: (name, value) => panelAttributes.set(name, String(value)),
          toggleAttribute (name, force) {
            if (name === 'inert') this.inert = force
          }
        }
        const hiddenToggle = makeToggle({ visible: false })
        const visibleToggle = makeToggle({ visible: true })
        const icons = [ { classList: classList() }, { classList: classList() } ]
        const destroyField = { value: destroyed ? '1' : '0' }
        const row = {
          id,
          type,
          inside,
          isConnected: true,
          style: { display: hidden ? 'none' : '' },
          classList: classList(open ? [ openClass ] : []),
          dataset: type === 'item'
            ? { receiptReviewItemRow: 'true' }
            : (reviewTarget ? { receiptReviewAdjustmentRow: 'true' } : {}),
          panel,
          toggles: [ hiddenToggle, visibleToggle ],
          hiddenToggle,
          visibleToggle,
          icons,
          destroyField,
          scrollCount: 0,
          matches (selector) {
            if (selector.includes(`receipt-review-${type}-row`)) return reviewTarget

            return selector.includes(`${type}Row`)
          },
          closest: () => null,
          querySelector (selector) {
            if (selector.includes(panelTarget)) return panel
            if (selector.includes(destroyTarget)) return destroyField
            return null
          },
          querySelectorAll (selector) {
            if (selector.includes(toggleTarget)) return this.toggles
            if (selector.includes(iconTarget)) return this.icons
            return []
          },
          scrollIntoView () { this.scrollCount += 1 }
        }
        hiddenToggle.row = row
        visibleToggle.row = row
        rows.push(row)
        return row
      }

      const section = (id) => ({
        id,
        inside: true,
        scrollCount: 0,
        scrollIntoView () { this.scrollCount += 1 }
      })
      const itemSection = section('receipt-section-items')
      const adjustmentSection = section('receipt-section-adjustments')
      const sections = new Map([
        [ itemSection.id, itemSection ],
        [ adjustmentSection.id, adjustmentSection ]
      ])
      const nodesForId = (id) => rows.filter((row) => row.id === id)

      const element = {
        contains: (node) => Boolean(node?.inside),
        addEventListener: (name, callback) => listeners.element.set(name, callback),
        removeEventListener: (name, callback) => {
          if (listeners.element.get(name) === callback) listeners.element.delete(name)
        },
        querySelectorAll (selector) {
          const idMatch = selector.match(/#([^ ]+)/) || selector.match(/\[id=["']?([^"'\]]+)/)
          return idMatch ? nodesForId(idMatch[1]) : []
        }
      }

      const makeLink = (targetId, fallbackTarget = adjustmentSection.id) => {
        const link = {
          inside: true,
          dataset: { reviewReasonTarget: fallbackTarget },
          getAttribute: (name) => name === 'href' ? `/receipts/rcpt_1/edit#${targetId}` : null,
          closest: (selector) => selector === 'a[data-review-reason-target-link]' ? link : null
        }
        links.push(link)
        return link
      }

      const makeClickEvent = (link) => ({
        target: link,
        prevented: false,
        preventDefault () { this.prevented = true }
      })

      globalThis.CSS = { escape: (value) => value }
      globalThis.fetch = () => { fetchCount += 1 }
      globalThis.document = {
        activeElement: null,
        addEventListener: (name, callback) => listeners.document.set(name, callback),
        removeEventListener: (name, callback) => {
          if (listeners.document.get(name) === callback) listeners.document.delete(name)
        },
        getElementById (id) {
          return nodesForId(id)[0] || sections.get(id) || null
        },
        querySelectorAll (selector) {
          const idMatch = selector.match(/#([^ ]+)/) || selector.match(/\[id=["']?([^"'\]]+)/)
          return idMatch ? nodesForId(idMatch[1]) : []
        }
      }
      globalThis.window = {
        location,
        history: {
          pushState (_state, _title, value) {
            location.hash = new URL(value, location.href).hash
          }
        },
        requestAnimationFrame: (callback) => callback(),
        setTimeout: (callback) => {
          callback()
          return 1
        },
        clearTimeout: () => {},
        getComputedStyle: (node) => ({
          display: node.visible === false ? 'none' : 'block',
          visibility: node.visible === false ? 'hidden' : 'visible'
        }),
        addEventListener: (name, callback) => listeners.window.set(name, callback),
        removeEventListener: (name, callback) => {
          if (listeners.window.get(name) === callback) listeners.window.delete(name)
        }
      }

      const makeController = () => {
        const controller = Object.create(ReceiptFormController.prototype)
        Object.defineProperties(controller, {
          element: { value: element },
          itemRowTargets: { get: () => rows.filter((row) => row.type === 'item') },
          adjustmentRowTargets: { get: () => rows.filter((row) => row.type === 'adjustment') },
          reviewItemTargetPrefixValue: { value: 'receipt-item-' },
          reviewItemsTargetValue: { value: itemSection.id },
          reviewAdjustmentTargetPrefixValue: { value: 'receipt-adjustment-' },
          reviewAdjustmentsTargetValue: { value: adjustmentSection.id }
        })
        return controller
      }

      #{script}
    JAVASCRIPT
  end

  def run_amount_round_trip(
    basis:,
    items:,
    adjustments: [],
    adjustment_tax_detail_rates: [],
    adjustment_tax_detail_evidence_stale: false,
    purchase_inputs_changed: false,
    purchase_input_baseline_trusted: nil,
    initial_receipt_amounts: nil,
    initial_tax_rate_summary: nil,
    add_blank_adjustment_after_initial: false,
    changed_first_tax_rate: nil,
    changed_discount_rate: nil,
    changed_price: nil,
    changed_reference_price: nil,
    changed_price_before_discount: nil,
    changed_quantity_unit: nil,
    reference_projection_fallback_tax_rate: '',
    item_line_total_max: 999_999_999,
    receipt_total_max: 999_999_999,
    receipt_tax_max: 999_999_999,
    capture_preview_unavailable: false,
    capture_line_displays: false,
    sync_initial_pricing_previews: false
  )
    run_controller_script(<<~JAVASCRIPT)
      const itemDefinitions = #{items.to_json}
      const adjustmentDefinitions = #{adjustments.to_json}
      const amountTarget = () => ({ value: null, textContent: '', title: '', dataset: {} })
      const rows = itemDefinitions.map((definition) => {
        const lineTotalDisplays = #{capture_line_displays.to_json}
          ? [false, true].map((withLabel) => ({
            ...amountTarget(),
            closest: () => withLabel ? {} : null
          }))
          : []
        const inputs = {
          quantityInput: { value: String(definition.quantity ?? 1) },
          quantityUnitInput: { value: String(definition.quantityUnit ?? 'each') },
          priceInput: { value: definition.price === null ? '' : String(definition.price) },
          pricingSourceModeInput: { value: String(definition.pricingSourceKind ?? '') },
          referencePriceAmountInput: { value: String(definition.referencePriceAmount ?? '') },
          referenceQuantityInput: { value: String(definition.referenceQuantity ?? '') },
          referenceQuantityUnitInput: { value: String(definition.referenceQuantityUnit ?? '') },
          referencePriceTaxInclusionInput: {
            value: String(definition.referencePriceTaxInclusion ?? ''),
            dataset: { receiptFormTaxInclusionLabel: String(definition.referencePriceTaxInclusion ?? '') }
          },
          explicitLineTotalInput: { value: String(definition.explicitLineTotal ?? '') },
          discountRateInput: {
            value: String(definition.discountRate ?? ''),
            dataset: { originalDiscountRate: String(definition.discountRate ?? '') }
          },
          taxRateInput: {
            value: definition.taxRate === null || definition.taxRate === undefined ? '' : String(definition.taxRate)
          },
          lineTotalInput: {
            value: definition.lineTotal === null || definition.lineTotal === undefined ? '' : String(definition.lineTotal),
            dataset: {
              originalLineTotal: definition.originalLineTotal === null || definition.originalLineTotal === undefined
                ? (definition.lineTotal === null || definition.lineTotal === undefined ? '' : String(definition.lineTotal))
                : String(definition.originalLineTotal),
              originalSavedLineTotal: definition.lineTotal === null || definition.lineTotal === undefined ? '' : String(definition.lineTotal)
            }
          },
          originalLineTotalInput: {
            value: definition.originalLineTotal === null || definition.originalLineTotal === undefined
              ? (definition.lineTotal === null || definition.lineTotal === undefined ? '' : String(definition.lineTotal))
              : String(definition.originalLineTotal)
          }
        }

        return {
          dataset: {
            receiptFormActivePricingMode: String(definition.pricingSourceKind ?? 'unclassified'),
            receiptFormHasPersistedAbsoluteDiscountSource: String(definition.hasAbsoluteDiscountSource ?? false)
          },
          inputs,
          lineTotalDisplays,
          querySelector (selector) {
            const match = selector.match(/receipt-form-target="([^"]+)"/)
            return match ? inputs[match[1]] : null
          },
          querySelectorAll (selector) {
            return selector.includes('lineTotalDisplay') ? lineTotalDisplays : []
          }
        }
      })
      const controller = Object.create(ReceiptFormController.prototype)
      const adjustmentRows = adjustmentDefinitions.map((definition) => {
        const inputs = {
          adjustmentAmountInput: { value: definition.amount === null ? '' : String(definition.amount) },
          adjustmentTaxRateInput: { value: definition.taxRate === null ? '' : String(definition.taxRate) }
        }

        return {
          definition,
          querySelector (selector) {
            const match = selector.match(/receipt-form-target="([^"]+)"/)
            return match ? inputs[match[1]] : null
          }
        }
      })
      const activeAdjustmentRows = #{add_blank_adjustment_after_initial.to_json} ? [] : adjustmentRows
      const subtotal = amountTarget()
      const tax = amountTarget()
      const total = amountTarget()
      const taxRateSummary = { textContent: #{initial_tax_rate_summary.to_json} }
      let paymentAdjustmentSnapshot = null

      Object.defineProperties(controller, {
        itemRowTargets: { value: rows },
        adjustmentRowTargets: { value: activeAdjustmentRows },
        paymentRowTargets: { value: [] },
        adjustmentTaxDetailRatesValue: { value: #{adjustment_tax_detail_rates.to_json} },
        adjustmentTaxDetailEvidenceStaleValue: { value: #{adjustment_tax_detail_evidence_stale.to_json} },
        purchaseInputsChangedValue: { value: #{purchase_inputs_changed.to_json} },
        receiptTaxBasisValue: { value: #{basis.to_json} },
        unsetLabelValue: { value: 'Unset' },
        subtotalLabelValue: { value: 'Subtotal' },
        multipleTaxRatesLabelValue: { value: 'Multiple tax rates' },
        roundingModeValue: { value: 'floor' },
        discountRoundingModeValue: { value: 'round' },
        countableQuantityUnitsValue: { value: 'each,piece,item,bottle,bag,box' },
        receiptItemPriceMaxValue: { value: 999999999 },
        receiptItemLineTotalMaxValue: { value: #{item_line_total_max} },
        referenceProjectionFallbackTaxRateValue: { value: #{reference_projection_fallback_tax_rate.to_json} },
        receiptAdjustmentAmountMaxValue: { value: 999999999 },
        receiptPaymentAmountMaxValue: { value: 999999999 },
        receiptTotalAmountMaxValue: { value: #{receipt_total_max} },
        receiptTaxAmountMaxValue: { value: #{receipt_tax_max} },
        hasTotalAmountTarget: { value: true },
        totalAmountTarget: { value: total },
        hasSubtotalAmountTarget: { value: true },
        subtotalAmountTarget: { value: subtotal },
        hasTaxAmountTarget: { value: true },
        taxAmountTarget: { value: tax },
        hasTaxRateSummaryTarget: { value: #{(!initial_tax_rate_summary.nil?).to_json} },
        taxRateSummaryTarget: { value: taxRateSummary }
      })

      controller.previewNumericInputsValid = () => true
      controller.previewRowExcluded = () => false
      controller.animateAmount = (target, value) => { target.value = value }
      controller.shouldRenderAmountImmediately = () => true
      let previewUnavailable = false
      if (#{capture_preview_unavailable.to_json}) {
        controller.renderUnavailablePreview = () => { previewUnavailable = true }
      }
      controller.syncAdjustmentSignForRow = () => {}
      controller.adjustmentEffectForRow = (row) => row.definition.effect
      controller.adjustmentSignForRow = (row) => row.definition.sign
      controller.syncPaymentAdjustmentSummary = (adjustmentTotal, finalPaymentTotal) => {
        paymentAdjustmentSnapshot = { adjustmentTotal, finalPaymentTotal }
      }
      controller.syncPaymentReconciliationSummary = () => {}
      controller.paymentAmountSum = () => 801
      controller.initialReceiptAmounts = #{initial_receipt_amounts.to_json}
      if (controller.initialReceiptAmounts && #{(!initial_tax_rate_summary.nil?).to_json}) {
        controller.initialReceiptAmounts.taxRateSummary = #{initial_tax_rate_summary.to_json}
      }
      controller.initialPurchaseInputFingerprint = controller.purchaseInputFingerprint()
      controller.purchaseInputBaselineTrusted = #{(purchase_input_baseline_trusted.nil? ? !purchase_inputs_changed : purchase_input_baseline_trusted).to_json}
      if (#{add_blank_adjustment_after_initial.to_json}) activeAdjustmentRows.push(...adjustmentRows)

      const snapshot = () => {
        const amounts = {
          subtotal: subtotal.value,
          tax: tax.value,
          total: total.value,
          firstLineTotal: rows[0].inputs.lineTotalInput.value === '' ? null : Number(rows[0].inputs.lineTotalInput.value)
        }

        if (#{capture_line_displays.to_json}) {
          amounts.lineDisplays = rows.map((row) => row.lineTotalDisplays.map((target) => ({
            text: target.textContent,
            title: target.title,
            amount: target.dataset.amountValue ?? null
          })))
        }
        if (adjustmentDefinitions.length > 0) {
          amounts.paymentAdjustmentTotal = paymentAdjustmentSnapshot.adjustmentTotal
          amounts.finalPaymentTotal = paymentAdjustmentSnapshot.finalPaymentTotal
        }
        if (itemDefinitions[0].captureOriginalLineTotal) {
          amounts.sourceOriginalLineTotal = Number(rows[0].inputs.originalLineTotalInput.value)
        }
        if (itemDefinitions[0].captureBlankSources) {
          amounts.sourceLineTotal = String(rows[0].inputs.lineTotalInput.value ?? '')
          amounts.sourceOriginalLineTotal = String(rows[0].inputs.originalLineTotalInput.value ?? '')
        }
        if (#{(!initial_tax_rate_summary.nil?).to_json}) {
          amounts.taxRateSummary = taxRateSummary.textContent
        }
        if (#{capture_preview_unavailable.to_json}) amounts.previewUnavailable = previewUnavailable

        return amounts
      }

      if (#{sync_initial_pricing_previews.to_json}) {
        controller.syncInitialPricingPreviews()
      } else {
        controller.recalculate()
      }
      const initial = snapshot()
      const changedDiscountRate = #{changed_discount_rate.to_json}
      const changedPrice = #{changed_price.to_json}
      const changedReferencePrice = #{changed_reference_price.to_json}
      const changedPriceBeforeDiscount = #{changed_price_before_discount.to_json}
      const changedQuantityUnit = #{changed_quantity_unit.to_json}
      let doubled
      let restored
      let result
      if (changedPriceBeforeDiscount !== null) {
        const initialPrice = rows[0].inputs.priceInput.value
        rows[0].inputs.priceInput.value = String(changedPriceBeforeDiscount)
        controller.recalculate()
        const priceEntered = snapshot()
        rows[0].inputs.priceInput.value = initialPrice
        controller.recalculate()
        const priceRestored = snapshot()
        if (changedQuantityUnit !== null) rows[0].inputs.quantityUnitInput.value = String(changedQuantityUnit)
        rows[0].inputs.discountRateInput.value = String(changedDiscountRate)
        controller.recalculate()
        const discounted = snapshot()
        result = { initial, priceEntered, priceRestored, discounted }
      } else if (changedDiscountRate !== null) {
        const initialDiscountRate = rows[0].inputs.discountRateInput.value
        const initialQuantityUnit = rows[0].inputs.quantityUnitInput.value
        if (changedQuantityUnit !== null) rows[0].inputs.quantityUnitInput.value = String(changedQuantityUnit)
        rows[0].inputs.discountRateInput.value = String(changedDiscountRate)
        controller.recalculate()
        doubled = snapshot()
        rows[0].inputs.discountRateInput.value = initialDiscountRate
        rows[0].inputs.quantityUnitInput.value = initialQuantityUnit
        controller.recalculate()
        restored = snapshot()
      } else if (changedReferencePrice !== null) {
        rows[0].inputs.referencePriceAmountInput.value = String(changedReferencePrice)
        controller.recalculate()
        doubled = snapshot()
      } else if (changedPrice !== null) {
        const initialPrice = rows[0].inputs.priceInput.value
        rows[0].inputs.priceInput.value = String(changedPrice)
        controller.recalculate()
        doubled = snapshot()
        rows[0].inputs.priceInput.value = initialPrice
        controller.recalculate()
        restored = snapshot()
      } else {
        rows[0].inputs.quantityInput.value = '2'
        controller.recalculate()
        doubled = snapshot()
        rows[0].inputs.quantityInput.value = '1'
        controller.recalculate()
        restored = snapshot()
      }

      if (!result) result = { initial, doubled, restored }
      const changedFirstTaxRate = #{changed_first_tax_rate.to_json}
      if (changedFirstTaxRate !== null) {
        rows[0].inputs.taxRateInput.value = String(changedFirstTaxRate)
        controller.recalculate()
        result.changedFirstTaxRate = snapshot()
      }

      process.stdout.write(JSON.stringify(result))
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

  it "opens only the linked adjustment and focuses its visible toggle for a same-page activation" do
    result = run_review_target_script(<<~JAVASCRIPT)
      const target = makeRow({ id: 'receipt-adjustment-42', type: 'adjustment' })
      const openAdjustment = makeRow({ id: 'receipt-adjustment-43', type: 'adjustment', open: true })
      const openItem = makeRow({ id: 'receipt-item-7', type: 'item', open: true })
      const link = makeLink(target.id)
      const event = makeClickEvent(link)
      const controller = makeController()

      controller.handleReviewTargetClick(event)
      controller.handleReviewTargetClick(makeClickEvent(link))

      process.stdout.write(JSON.stringify({
        prevented: event.prevented,
        hash: window.location.hash,
        targetOpen: target.panel.classList.contains('is-open'),
        targetAriaHidden: target.panel.getAttribute('aria-hidden'),
        targetInert: target.panel.inert,
        targetToggleExpanded: target.toggles.map((toggle) => toggle.getAttribute('aria-expanded')),
        hiddenToggleFocus: target.hiddenToggle.focusCount,
        visibleToggleFocus: target.visibleToggle.focusCount,
        visibleTogglePreventScroll: target.visibleToggle.focusOptions.every((options) => options?.preventScroll === true),
        otherAdjustmentOpen: openAdjustment.panel.classList.contains('is-open'),
        itemOpen: openItem.panel.classList.contains('is-open'),
        targetScrolls: target.scrollCount,
        fetchCount
      }))
    JAVASCRIPT

    expect(result).to eq(
      "prevented" => true,
      "hash" => "#receipt-adjustment-42",
      "targetOpen" => true,
      "targetAriaHidden" => "false",
      "targetInert" => false,
      "targetToggleExpanded" => [ "true", "true" ],
      "hiddenToggleFocus" => 0,
      "visibleToggleFocus" => 2,
      "visibleTogglePreventScroll" => true,
      "otherAdjustmentOpen" => true,
      "itemOpen" => true,
      "targetScrolls" => 2,
      "fetchCount" => 0
    )
  end

  it "opens adjustment hashes without moving focus and keeps previously opened rows expanded" do
    result = run_review_target_script(<<~JAVASCRIPT)
      const first = makeRow({ id: 'receipt-adjustment-42', type: 'adjustment' })
      const second = makeRow({ id: 'receipt-adjustment-43', type: 'adjustment' })
      const openItem = makeRow({ id: 'receipt-item-7', type: 'item', open: true })
      const controller = makeController()

      window.location.hash = '#receipt-adjustment-42'
      controller.handleHashChange()
      window.location.hash = '#receipt-adjustment-43'
      controller.handleHashChange()
      window.location.hash = '#receipt-adjustment-42'
      controller.handleHashChange()

      process.stdout.write(JSON.stringify({
        firstOpen: first.panel.classList.contains('is-open'),
        secondOpen: second.panel.classList.contains('is-open'),
        itemOpen: openItem.panel.classList.contains('is-open'),
        firstFocus: first.toggles.reduce((sum, toggle) => sum + toggle.focusCount, 0),
        secondFocus: second.toggles.reduce((sum, toggle) => sum + toggle.focusCount, 0),
        firstScrolls: first.scrollCount,
        secondScrolls: second.scrollCount,
        fetchCount
      }))
    JAVASCRIPT

    expect(result).to eq(
      "firstOpen" => true,
      "secondOpen" => true,
      "itemOpen" => true,
      "firstFocus" => 0,
      "secondFocus" => 0,
      "firstScrolls" => 2,
      "secondScrolls" => 1,
      "fetchCount" => 0
    )
  end

  it "falls back to the adjustment section for unusable same-page adjustment targets" do
    result = run_review_target_script(<<~JAVASCRIPT)
      makeRow({ id: 'receipt-adjustment-deleted', type: 'adjustment', destroyed: true })
      makeRow({ id: 'receipt-adjustment-hidden', type: 'adjustment', hidden: true })
      makeRow({ id: 'receipt-adjustment-foreign', type: 'adjustment', inside: false })
      makeRow({ id: 'receipt-adjustment-unsaved', type: 'adjustment', reviewTarget: false })
      makeRow({ id: 'receipt-adjustment-duplicate', type: 'adjustment' })
      makeRow({ id: 'receipt-adjustment-duplicate', type: 'adjustment' })
      const controller = makeController()
      const targetIds = [
        'receipt-adjustment-missing',
        'receipt-adjustment-deleted',
        'receipt-adjustment-hidden',
        'receipt-adjustment-foreign',
        'receipt-adjustment-unsaved',
        'receipt-adjustment-NEW_ADJUSTMENT_RECORD',
        'receipt-adjustment-duplicate'
      ]
      const results = targetIds.map((targetId) => {
        window.location.hash = ''
        const event = makeClickEvent(makeLink(targetId, itemSection.id))
        controller.handleReviewTargetClick(event)
        return { targetId, prevented: event.prevented, hash: window.location.hash }
      })

      process.stdout.write(JSON.stringify({
        results,
        fallbackScrolls: adjustmentSection.scrollCount,
        openedRows: rows.filter((row) => row.panel.classList.contains('is-open')).map((row) => row.id),
        focusedToggles: rows.flatMap((row) => row.toggles).reduce((sum, toggle) => sum + toggle.focusCount, 0),
        fetchCount
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["results"]).to all(include(
        "prevented" => true,
        "hash" => "#receipt-section-adjustments"
      ))
      expect(result).to include(
        "fallbackScrolls" => 7,
        "openedRows" => [],
        "focusedToggles" => 0,
        "fetchCount" => 0
      )
    end
  end

  it "keeps receipt-level review section links in the current Turbo document" do
    result = run_review_target_script(<<~JAVASCRIPT)
      const controller = makeController()
      const itemEvent = makeClickEvent(makeLink(itemSection.id))
      const adjustmentEvent = makeClickEvent(makeLink(adjustmentSection.id))

      controller.handleReviewTargetClick(itemEvent)
      controller.handleReviewTargetClick(adjustmentEvent)

      process.stdout.write(JSON.stringify({
        itemPrevented: itemEvent.prevented,
        adjustmentPrevented: adjustmentEvent.prevented,
        hash: window.location.hash,
        itemScrolls: itemSection.scrollCount,
        adjustmentScrolls: adjustmentSection.scrollCount,
        fetchCount
      }))
    JAVASCRIPT

    expect(result).to eq(
      "itemPrevented" => true,
      "adjustmentPrevented" => true,
      "hash" => "#receipt-section-adjustments",
      "itemScrolls" => 1,
      "adjustmentScrolls" => 1,
      "fetchCount" => 0
    )
  end

  it "opens every visible item and focuses the persistent summary after an invalid source response" do
    result = run_review_target_script(<<~JAVASCRIPT)
      const first = makeRow({ id: 'receipt-item-1', type: 'item' })
      const second = makeRow({ id: 'receipt-item-2', type: 'item' })
      const destroyed = makeRow({ id: 'receipt-item-3', type: 'item', destroyed: true })
      const hidden = makeRow({ id: 'receipt-item-4', type: 'item', hidden: true })
      const summary = {
        hidden: false,
        isConnected: true,
        focusCount: 0,
        focusOptions: [],
        scrollCount: 0,
        focus (options) {
          this.focusCount += 1
          this.focusOptions.push(options)
          document.activeElement = this
        },
        scrollIntoView () { this.scrollCount += 1 }
      }
      const controller = makeController()
      Object.defineProperties(controller, {
        hasInvalidItemSourceSummaryTarget: { value: true },
        invalidItemSourceSummaryTarget: { value: summary }
      })

      controller.revealInvalidItemSourceRows()

      process.stdout.write(JSON.stringify({
        firstOpen: first.panel.classList.contains('is-open'),
        secondOpen: second.panel.classList.contains('is-open'),
        destroyedOpen: destroyed.panel.classList.contains('is-open'),
        hiddenOpen: hidden.panel.classList.contains('is-open'),
        focusCount: summary.focusCount,
        focusPreventScroll: summary.focusOptions[0]?.preventScroll,
        scrollCount: summary.scrollCount
      }))
    JAVASCRIPT

    expect(result).to eq(
      "firstOpen" => true,
      "secondOpen" => true,
      "destroyedOpen" => false,
      "hiddenOpen" => false,
      "focusCount" => 1,
      "focusPreventScroll" => true,
      "scrollCount" => 1
    )
  end

  it "opens a collapsed item before the browser focuses an invalid detail field" do
    result = run_review_target_script(<<~JAVASCRIPT)
      const row = makeRow({ id: 'receipt-item-1', type: 'item' })
      const invalidInput = { closest: () => row }
      row.panel.contains = (candidate) => candidate === invalidInput
      const controller = makeController()

      controller.handleInvalidItemField({ target: invalidInput })

      process.stdout.write(JSON.stringify({
        panelOpen: row.panel.classList.contains('is-open'),
        panelInert: row.panel.inert,
        ariaHidden: row.panel.getAttribute('aria-hidden'),
        expanded: row.toggles.map((toggle) => toggle.getAttribute('aria-expanded'))
      }))
    JAVASCRIPT

    expect(result).to eq(
      "panelOpen" => true,
      "panelInert" => false,
      "ariaHidden" => "false",
      "expanded" => [ "true", "true" ]
    )
  end

  it "restores adjustment targets idempotently across Turbo cache and Stimulus reconnects" do
    result = run_review_target_script(<<~JAVASCRIPT)
      const target = makeRow({ id: 'receipt-adjustment-42', type: 'adjustment' })
      const controller = makeController()
      controller.syncQuantityInputSteps = () => {}
      controller.syncAdjustmentSigns = () => {}
      controller.captureInitialReceiptAmounts = () => {}
      controller.captureInitialPurchaseInputFingerprint = () => {}
      controller.syncPaymentSummaryLayout = () => {}
      controller.clearLineTotalTooltipTimer = () => {}
      controller.amountAnimationTargets = () => []

      window.location.hash = '#receipt-adjustment-42'
      controller.connect()
      const firstListenerCounts = {
        beforeCache: listeners.document.has('turbo:before-cache') ? 1 : 0,
        click: listeners.element.has('click') ? 1 : 0,
        hashchange: listeners.window.has('hashchange') ? 1 : 0
      }
      listeners.document.get('turbo:before-cache')()
      controller.disconnect()
      const disconnectedListenerCount = listeners.document.size + listeners.element.size + listeners.window.size
      controller.connect()
      const secondListenerCounts = {
        beforeCache: listeners.document.has('turbo:before-cache') ? 1 : 0,
        click: listeners.element.has('click') ? 1 : 0,
        hashchange: listeners.window.has('hashchange') ? 1 : 0
      }
      target.scrollCount = 0
      listeners.window.get('hashchange')()

      process.stdout.write(JSON.stringify({
        firstListenerCounts,
        disconnectedListenerCount,
        secondListenerCounts,
        targetOpen: target.panel.classList.contains('is-open'),
        targetFocus: target.toggles.reduce((sum, toggle) => sum + toggle.focusCount, 0),
        hashchangeScrolls: target.scrollCount,
        fetchCount
      }))
    JAVASCRIPT

    expect(result).to eq(
      "firstListenerCounts" => { "beforeCache" => 1, "click" => 1, "hashchange" => 1 },
      "disconnectedListenerCount" => 0,
      "secondListenerCounts" => { "beforeCache" => 1, "click" => 1, "hashchange" => 1 },
      "targetOpen" => true,
      "targetFocus" => 0,
      "hashchangeScrolls" => 1,
      "fetchCount" => 0
    )
  end

  it "synchronizes adjustment absence confirmation with active adjustment rows" do
    result = run_controller_script(<<~JAVASCRIPT)
      const rows = []
      const attributes = new Map()
      const panel = {
        hidden: true,
        inert: true,
        toggleAttribute (name, force) {
          if (name === 'inert') this.inert = force
        },
        setAttribute (name, value) {
          attributes.set(name, String(value))
        }
      }
      const field = { checked: false }
      const controller = Object.create(ReceiptFormController.prototype)
      Object.defineProperties(controller, {
        hasAdjustmentAbsenceConfirmationTarget: { value: true },
        adjustmentAbsenceConfirmationTarget: { value: panel },
        hasAdjustmentAbsenceConfirmationFieldTarget: { value: true },
        adjustmentAbsenceConfirmationFieldTarget: { value: field },
        adjustmentRowTargets: { get: () => rows }
      })
      controller.previewRowExcluded = (row) => row.excluded
      controller.syncItemDetailsPanels = () => {}
      controller.syncAdjustmentDetailsPanels = () => {}
      controller.syncAdjustmentSigns = () => {}

      const snapshot = () => ({
        hidden: panel.hidden,
        inert: panel.inert,
        ariaHidden: attributes.get('aria-hidden'),
        checked: field.checked
      })

      controller.syncAdjustmentAbsenceConfirmation()
      const initial = snapshot()

      field.checked = true
      const row = { excluded: false }
      rows.push(row)
      controller.syncAdjustmentAbsenceConfirmation()
      const added = snapshot()

      row.excluded = true
      controller.handleBeforeCache()
      const removedBeforeCache = snapshot()

      field.checked = true
      row.excluded = false
      controller.syncAdjustmentAbsenceConfirmation()
      const reconnectWithActiveRow = snapshot()

      process.stdout.write(JSON.stringify({ initial, added, removedBeforeCache, reconnectWithActiveRow }))
    JAVASCRIPT

    expect(result).to eq(
      "initial" => { "hidden" => false, "inert" => false, "ariaHidden" => "false", "checked" => false },
      "added" => { "hidden" => true, "inert" => true, "ariaHidden" => "true", "checked" => false },
      "removedBeforeCache" => { "hidden" => false, "inert" => false, "ariaHidden" => "false", "checked" => false },
      "reconnectWithActiveRow" => { "hidden" => true, "inert" => true, "ariaHidden" => "true", "checked" => false }
    )
  end

  it "keeps persisted countable line total baselines immutable during recalculation" do
    aggregate_failures do
      expect(source).not_to include("lineTotalInput.dataset.originalLineTotal = String(originalLineTotal)")
      expect(source).not_to include("lineTotalInput.dataset.originalSavedLineTotal = String(lineTotal)")
      expect(source).to include("lineTotalInput.dataset.workingOriginalLineTotal = String(originalLineTotal)")
      expect(source).to include("originalLineTotalInput.value = originalLineTotal")
    end
  end

  it "does not rewrite a quantity while the administrator is typing" do
    aggregate_failures do
      expect(source).not_to include("sanitizeQuantityInput")
      expect(source).not_to include("preventIntegerQuantityDecimalInput")
      expect(source).not_to include("clearFractionalQuantityForIntegerUnit")
      expect(source).not_to include("quantityUnitSelectForInput")
      expect(source).not_to include("integerQuantityInput")
    end
  end

  it "keeps inactive pricing drafts in the DOM but omits them from submission" do
    result = run_controller_script(<<~JAVASCRIPT)
      ;(async () => {
      const input = (value) => ({ value, disabled: false })
      const modeInput = input('reference_quantity_price')
      const price = input('125')
      const referencePrice = input('120')
      const referenceQuantity = input('500')
      const referenceUnit = input('milliliter')
      const referenceTax = input('gross')
      const explicitTotal = input('360')
      const originalTotal = input('360')
      const clearDiscount = input('0')
      const panels = []
      const panel = (modes, inputs) => {
        const attributes = new Map()
        const element = {
          dataset: { receiptFormPricingModes: modes },
          hidden: false,
          inert: false,
          inputs,
          toggleAttribute (name, force) { if (name === 'inert') this.inert = force },
          setAttribute (name, value) { attributes.set(name, String(value)) },
          querySelectorAll () { return this.inputs }
        }
        panels.push(element)
        return element
      }
      const countPanel = panel('count_unit_price unclassified', [price, originalTotal])
      const referencePanel = panel('reference_quantity_price', [referencePrice, referenceQuantity, referenceUnit, referenceTax])
      const explicitPanel = panel('explicit_line_total', [explicitTotal])
      const targets = {
        pricingSourceModeInput: modeInput,
        priceInput: price,
        referencePriceAmountInput: referencePrice,
        referenceQuantityInput: referenceQuantity,
        referenceQuantityUnitInput: referenceUnit,
        referencePriceTaxInclusionInput: referenceTax,
        explicitLineTotalInput: explicitTotal,
        clearItemDiscountBeforeExplicitInput: clearDiscount
      }
      const row = {
        dataset: { receiptFormActivePricingMode: 'reference_quantity_price', receiptFormHasPersistedAbsoluteDiscountSource: 'false' },
        querySelector (selector) {
          const match = selector.match(/receipt-form-target="([^"]+)"/)
          return match ? targets[match[1]] ?? null : null
        },
        querySelectorAll (selector) {
          if (selector.includes('pricingModePanel')) return panels
          return []
        }
      }
      modeInput.closest = () => row
      const controller = Object.create(ReceiptFormController.prototype)
      Object.defineProperty(controller, 'itemRowTargets', { value: [row] })
      let recalculations = 0
      controller.recalculate = () => { recalculations += 1 }
      const snapshot = () => ({
        active: row.dataset.receiptFormActivePricingMode,
        count: { hidden: countPanel.hidden, disabled: price.disabled, value: price.value },
        reference: { hidden: referencePanel.hidden, disabled: referencePrice.disabled, value: referencePrice.value },
        explicit: { hidden: explicitPanel.hidden, disabled: explicitTotal.disabled, value: explicitTotal.value }
      })

      controller.syncPricingSourceModes()
      const reference = snapshot()
      modeInput.value = 'explicit_line_total'
      await controller.pricingSourceModeChanged({ currentTarget: modeInput })
      const explicit = snapshot()
      modeInput.value = 'reference_quantity_price'
      await controller.pricingSourceModeChanged({ currentTarget: modeInput })
      controller.syncPricingSourceModes()
      const restored = snapshot()

      process.stdout.write(JSON.stringify({ reference, explicit, restored, recalculations }))
      })()
    JAVASCRIPT

    expect(result).to eq(
      "reference" => {
        "active" => "reference_quantity_price",
        "count" => { "hidden" => true, "disabled" => true, "value" => "125" },
        "reference" => { "hidden" => false, "disabled" => false, "value" => "120" },
        "explicit" => { "hidden" => true, "disabled" => true, "value" => "360" }
      },
      "explicit" => {
        "active" => "explicit_line_total",
        "count" => { "hidden" => true, "disabled" => true, "value" => "125" },
        "reference" => { "hidden" => true, "disabled" => true, "value" => "120" },
        "explicit" => { "hidden" => false, "disabled" => false, "value" => "360" }
      },
      "restored" => {
        "active" => "reference_quantity_price",
        "count" => { "hidden" => true, "disabled" => true, "value" => "125" },
        "reference" => { "hidden" => false, "disabled" => false, "value" => "120" },
        "explicit" => { "hidden" => true, "disabled" => true, "value" => "360" }
      },
      "recalculations" => 2
    )
  end

  it "cancels or atomically confirms a discounted formula transition to explicit total" do
    result = run_controller_script(<<~JAVASCRIPT)
      ;(async () => {
      const mode = { value: 'explicit_line_total' }
      const discount = { value: '10' }
      const clearIntent = { value: '0' }
      const targets = {
        pricingSourceModeInput: mode,
        discountRateInput: discount,
        clearItemDiscountBeforeExplicitInput: clearIntent
      }
      const row = {
        dataset: { receiptFormActivePricingMode: 'reference_quantity_price', receiptFormHasPersistedAbsoluteDiscountSource: 'false' },
        querySelector (selector) {
          const match = selector.match(/receipt-form-target="([^"]+)"/)
          return match ? targets[match[1]] ?? null : null
        },
        querySelectorAll () { return [] }
      }
      mode.closest = () => row
      discount.closest = () => row
      const controller = Object.create(ReceiptFormController.prototype)
      const answers = [false, true]
      controller.confirmPricingSourceDiscountClear = () => Promise.resolve(answers.shift())
      controller.recalculate = () => {}

      await controller.pricingSourceModeChanged({ currentTarget: mode })
      const cancelled = {
        mode: mode.value,
        active: row.dataset.receiptFormActivePricingMode,
        discount: discount.value,
        clearIntent: clearIntent.value
      }

      mode.value = 'explicit_line_total'
      await controller.pricingSourceModeChanged({ currentTarget: mode })
      const confirmed = {
        mode: mode.value,
        active: row.dataset.receiptFormActivePricingMode,
        discount: discount.value,
        clearIntent: clearIntent.value
      }

      mode.value = 'reference_quantity_price'
      await controller.pricingSourceModeChanged({ currentTarget: mode })
      const restored = {
        mode: mode.value,
        active: row.dataset.receiptFormActivePricingMode,
        discount: discount.value,
        clearIntent: clearIntent.value
      }

      process.stdout.write(JSON.stringify({ cancelled, confirmed, restored }))
      })()
    JAVASCRIPT

    expect(result).to eq(
      "cancelled" => {
        "mode" => "reference_quantity_price",
        "active" => "reference_quantity_price",
        "discount" => "10",
        "clearIntent" => "0"
      },
      "confirmed" => {
        "mode" => "explicit_line_total",
        "active" => "explicit_line_total",
        "discount" => "",
        "clearIntent" => "1"
      },
      "restored" => {
        "mode" => "reference_quantity_price",
        "active" => "reference_quantity_price",
        "discount" => "10",
        "clearIntent" => "0"
      }
    )
  end

  it "requires confirmation when a saved formula discount rate was cleared in the current draft" do
    result = run_controller_script(<<~JAVASCRIPT)
      ;(async () => {
      const mode = { value: 'explicit_line_total' }
      const discount = { value: '' }
      const clearIntent = { value: '0' }
      const targets = {
        pricingSourceModeInput: mode,
        discountRateInput: discount,
        clearItemDiscountBeforeExplicitInput: clearIntent
      }
      const row = {
        dataset: {
          receiptFormActivePricingMode: 'count_unit_price',
          receiptFormHasPersistedAbsoluteDiscountSource: 'false',
          receiptFormPersistedFormulaDiscountInput: '10'
        },
        querySelector (selector) {
          const match = selector.match(/receipt-form-target="([^"]+)"/)
          return match ? targets[match[1]] ?? null : null
        },
        querySelectorAll () { return [] }
      }
      mode.closest = () => row
      const controller = Object.create(ReceiptFormController.prototype)
      const answers = [false, true]
      let confirmationCount = 0
      controller.confirmPricingSourceDiscountClear = () => {
        confirmationCount += 1
        return Promise.resolve(answers.shift())
      }
      controller.recalculate = () => {}

      await controller.pricingSourceModeChanged({ currentTarget: mode })
      const cancelled = { mode: mode.value, discount: discount.value, intent: clearIntent.value }
      mode.value = 'explicit_line_total'
      await controller.pricingSourceModeChanged({ currentTarget: mode })
      const confirmed = { mode: mode.value, discount: discount.value, intent: clearIntent.value }

      process.stdout.write(JSON.stringify({ confirmationCount, cancelled, confirmed }))
      })()
    JAVASCRIPT

    expect(result).to eq(
      "confirmationCount" => 2,
      "cancelled" => { "mode" => "count_unit_price", "discount" => "", "intent" => "0" },
      "confirmed" => { "mode" => "explicit_line_total", "discount" => "", "intent" => "1" }
    )
  end

  it "does not rewrite source values or the pricing mode when a purchased unit changes" do
    result = run_controller_script(<<~JAVASCRIPT)
      const quantity = { value: '1.5', step: '', inputMode: '' }
      const unit = { value: 'kilogram' }
      const mode = { value: 'reference_quantity_price' }
      const referencePrice = { value: '498' }
      const referenceQuantity = { value: '100' }
      const referenceUnit = { value: 'gram' }
      const row = {
        querySelector (selector) {
          if (selector.includes('quantityInput')) return quantity
          if (selector.includes('pricingSourceModeInput')) return mode
          if (selector.includes('referencePriceAmountInput')) return referencePrice
          if (selector.includes('referenceQuantityInput')) return referenceQuantity
          if (selector.includes('referenceQuantityUnitInput')) return referenceUnit
          return null
        }
      }
      unit.closest = () => row
      const controller = Object.create(ReceiptFormController.prototype)
      Object.defineProperties(controller, {
        decimalQuantityUnitsValue: { value: 'gram,kilogram,milligram,liter,milliliter,cubic_centimeter' },
        decimalQuantityStepValue: { value: '0.001' },
        integerQuantityStepValue: { value: '1' }
      })
      let recalculated = false
      controller.recalculate = () => { recalculated = true }

      controller.quantityUnitChanged({ currentTarget: unit })

      process.stdout.write(JSON.stringify({
        quantity: quantity.value,
        step: quantity.step,
        inputMode: quantity.inputMode,
        mode: mode.value,
        referencePrice: referencePrice.value,
        referenceQuantity: referenceQuantity.value,
        referenceUnit: referenceUnit.value,
        recalculated
      }))
    JAVASCRIPT

    expect(result).to eq(
      "quantity" => "1.5",
      "step" => "0.001",
      "inputMode" => "decimal",
      "mode" => "reference_quantity_price",
      "referencePrice" => "498",
      "referenceQuantity" => "100",
      "referenceUnit" => "gram",
      "recalculated" => true
    )
  end

  it "updates only reference quantity input attributes when its unit changes" do
    result = run_controller_script(<<~JAVASCRIPT)
      const purchasedQuantity = { value: '2', step: '1', inputMode: 'numeric' }
      const referenceQuantity = { value: '1.5', step: '0.001', inputMode: 'decimal' }
      const referenceUnit = { value: 'each' }
      const row = {
        querySelector (selector) {
          if (selector.includes('referenceQuantityInput')) return referenceQuantity
          if (selector.includes('quantityInput')) return purchasedQuantity
          return null
        }
      }
      referenceUnit.closest = () => row
      const controller = Object.create(ReceiptFormController.prototype)
      Object.defineProperties(controller, {
        decimalQuantityUnitsValue: { value: 'gram,kilogram,milligram,liter,milliliter,cubic_centimeter' },
        decimalQuantityStepValue: { value: '0.001' },
        integerQuantityStepValue: { value: '1' }
      })
      let recalculations = 0
      controller.recalculate = () => { recalculations += 1 }

      controller.referenceQuantityUnitChanged({ currentTarget: referenceUnit })

      process.stdout.write(JSON.stringify({
        reference: {
          value: referenceQuantity.value,
          step: referenceQuantity.step,
          inputMode: referenceQuantity.inputMode
        },
        purchased: {
          value: purchasedQuantity.value,
          step: purchasedQuantity.step,
          inputMode: purchasedQuantity.inputMode
        },
        recalculations
      }))
    JAVASCRIPT

    expect(result).to eq(
      "reference" => { "value" => "1.5", "step" => "1", "inputMode" => "numeric" },
      "purchased" => { "value" => "2", "step" => "1", "inputMode" => "numeric" },
      "recalculations" => 1
    )
  end

  it "synchronizes required with the selected pricing authority" do
    result = run_controller_script(<<~JAVASCRIPT)
      const requiredInput = {
        disabled: false,
        required: false,
        dataset: { receiptFormRequiredWhenActive: 'true' }
      }
      const panel = {
        dataset: { receiptFormPricingModes: 'reference_quantity_price' },
        hidden: false,
        toggleAttribute () {},
        setAttribute () {},
        querySelectorAll () { return [requiredInput] }
      }
      const modeInput = { value: 'reference_quantity_price' }
      const row = {
        dataset: {},
        querySelector: () => modeInput,
        querySelectorAll (selector) { return selector.includes('pricingModePanel') ? [panel] : [] }
      }
      const controller = Object.create(ReceiptFormController.prototype)

      controller.syncPricingSourceModeForRow(row, 'reference_quantity_price')
      const active = { disabled: requiredInput.disabled, required: requiredInput.required }
      controller.syncPricingSourceModeForRow(row, 'explicit_line_total')
      const inactive = { disabled: requiredInput.disabled, required: requiredInput.required }

      process.stdout.write(JSON.stringify({ active, inactive }))
    JAVASCRIPT

    expect(result).to eq(
      "active" => { "disabled" => false, "required" => true },
      "inactive" => { "disabled" => true, "required" => false }
    )
  end

  it "fingerprints only the selected pricing source across Turbo reconnects" do
    result = run_controller_script(<<~JAVASCRIPT)
      const inputs = {
        pricingSourceModeInput: { value: 'reference_quantity_price' },
        quantityInput: { value: '1.5' },
        quantityUnitInput: { value: 'liter' },
        priceInput: { value: '999' },
        referencePriceAmountInput: { value: '120' },
        referenceQuantityInput: { value: '500' },
        referenceQuantityUnitInput: { value: 'milliliter' },
        referencePriceTaxInclusionInput: { value: 'gross' },
        explicitLineTotalInput: { value: '360' },
        discountRateInput: { value: '' },
        taxRateInput: { value: '10' },
        lineTotalInput: { value: '360', dataset: { originalLineTotal: '360', originalSavedLineTotal: '360' } }
      }
      const row = {
        style: { display: '' },
        dataset: { receiptFormActivePricingMode: 'reference_quantity_price' },
        querySelector (selector) {
          const match = selector.match(/receipt-form-target="([^"]+)"/)
          return match ? inputs[match[1]] ?? null : null
        }
      }
      const controller = Object.create(ReceiptFormController.prototype)
      Object.defineProperties(controller, {
        itemRowTargets: { value: [row] },
        adjustmentRowTargets: { value: [] },
        countableQuantityUnitsValue: { value: 'each,item,piece,bag,sheet,unit,box,set' }
      })

      const reference = controller.purchaseInputFingerprint()
      inputs.priceInput.value = '1'
      const inactiveDraftChanged = controller.purchaseInputFingerprint()
      inputs.referencePriceAmountInput.value = '121'
      const referenceChanged = controller.purchaseInputFingerprint()
      inputs.referencePriceAmountInput.value = '120'
      inputs.pricingSourceModeInput.value = 'explicit_line_total'
      row.dataset.receiptFormActivePricingMode = 'explicit_line_total'
      const explicit = controller.purchaseInputFingerprint()

      process.stdout.write(JSON.stringify({ reference, inactiveDraftChanged, referenceChanged, explicit }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["inactiveDraftChanged"]).to eq(result["reference"])
      expect(result["referenceChanged"]).not_to eq(result["reference"])
      expect(result["explicit"]).not_to eq(result["reference"])
      expect(JSON.parse(result["reference"])["items"].first.first).to eq("reference_quantity_price")
      expect(JSON.parse(result["explicit"])["items"].first.first).to eq("explicit_line_total")
    end
  end

  it "updates the selected pricing authority summary without exposing inactive drafts" do
    result = run_controller_script(<<~JAVASCRIPT)
      const amount = { value: '120' }
      const quantity = { value: '500' }
      const unit = { value: 'milliliter', selectedOptions: [{ textContent: 'ml' }] }
      const tax = { value: 'gross', dataset: { receiptFormTaxInclusionLabel: '税込' } }
      const summary = {
        textContent: '',
        dataset: {
          receiptFormPricingModes: 'reference_quantity_price',
          receiptFormSummaryTemplate: '%{amount}円 / %{quantity}%{unit}（%{tax_inclusion}）',
          receiptFormSummaryUnset: '基準価格と基準数量'
        }
      }
      const targets = {
        referencePriceAmountInput: amount,
        referenceQuantityInput: quantity,
        referenceQuantityUnitInput: unit,
        referencePriceTaxInclusionInput: tax
      }
      const row = {
        querySelector (selector) {
          const match = selector.match(/receipt-form-target="([^"]+)"/)
          return match ? targets[match[1]] ?? null : null
        },
        querySelectorAll (selector) {
          return selector.includes('pricingSourceSummary') ? [summary] : []
        }
      }
      const controller = Object.create(ReceiptFormController.prototype)

      controller.syncPricingSourceSummaryForRow(row, 'reference_quantity_price')
      const complete = summary.textContent
      amount.value = ''
      controller.syncPricingSourceSummaryForRow(row, 'reference_quantity_price')

      process.stdout.write(JSON.stringify({ complete, incomplete: summary.textContent }))
    JAVASCRIPT

    expect(result).to eq(
      "complete" => "120円 / 500ml（税込）",
      "incomplete" => "基準価格と基準数量"
    )
  end

  it "keeps a stored derived explicit total through initial and later unavailable preview rendering" do
    result = run_controller_script(<<~JAVASCRIPT)
      const modeInput = { value: 'explicit_line_total' }
      const explicitInput = { value: '' }
      const lineTotalInput = { value: '180', dataset: { originalLineTotal: '', originalSavedLineTotal: '180' } }
      const originalLineTotalInput = { value: '' }
      const storedLineDisplay = { textContent: '¥180', title: '¥180', dataset: {} }
      const receiptTotalDisplay = { textContent: '¥180', title: '¥180', dataset: {} }
      const inputs = {
        pricingSourceModeInput: modeInput,
        explicitLineTotalInput: explicitInput,
        lineTotalInput,
        originalLineTotalInput
      }
      const row = {
        dataset: { receiptFormExplicitLineTotalSourceMissing: 'true' },
        querySelector (selector) {
          const match = selector.match(/receipt-form-target="([^"]+)"/)
          return match ? inputs[match[1]] ?? null : null
        },
        querySelectorAll (selector) {
          return selector.includes('lineTotalDisplay') ? [storedLineDisplay] : []
        }
      }
      const controller = Object.create(ReceiptFormController.prototype)
      Object.defineProperties(controller, {
        itemRowTargets: { value: [row] },
        hasTaxRateSummaryTarget: { value: false },
        paymentMismatchWarningTargets: { value: [] },
        syncPaymentAmountButtonTargets: { value: [] }
      })
      controller.previewRowExcluded = () => false
      controller.previewAmountTargets = () => [storedLineDisplay, receiptTotalDisplay]
      controller.renderUnavailableAmount = (target) => { target.textContent = '—' }
      controller.syncPaymentSummaryLayout = () => {}
      let recalculateCount = 0
      controller.recalculate = () => { recalculateCount += 1 }

      controller.syncInitialPricingPreviews()
      storedLineDisplay.textContent = '¥180'
      receiptTotalDisplay.textContent = '¥180'
      controller.renderUnavailablePreview()

      process.stdout.write(JSON.stringify({
        recalculateCount,
        explicitValue: explicitInput.value,
        lineTotalValue: lineTotalInput.value,
        originalLineTotalValue: originalLineTotalInput.value,
        storedLineDisplay: storedLineDisplay.textContent,
        receiptTotalDisplay: receiptTotalDisplay.textContent
      }))
    JAVASCRIPT

    expect(result).to eq(
      'recalculateCount' => 0,
      'explicitValue' => '',
      'lineTotalValue' => '180',
      'originalLineTotalValue' => '',
      'storedLineDisplay' => '¥180',
      'receiptTotalDisplay' => '—'
    )
  end

  it "keeps a persisted positive explicit rate through blank and zero 422 inputs until clear intent" do
    result = run_controller_script(<<~JAVASCRIPT)
      const discount = { value: '' }
      const clearIntent = { value: '0' }
      const targets = {
        discountRateInput: discount,
        clearItemDiscountBeforeExplicitInput: clearIntent
      }
      const row = {
        dataset: {
          receiptFormHasPersistedAbsoluteDiscountSource: 'false',
          receiptFormHasPersistedExplicitPositiveDiscountRateSource: 'true'
        },
        querySelector (selector) {
          const match = selector.match(/receipt-form-target="([^"]+)"/)
          return match ? targets[match[1]] ?? null : null
        }
      }
      const controller = Object.create(ReceiptFormController.prototype)
      const blank = controller.itemDiscountSourcePresent(row)
      discount.value = '0'
      const zero = controller.itemDiscountSourcePresent(row)
      discount.value = ''
      clearIntent.value = '1'
      const cleared = controller.itemDiscountSourcePresent(row)
      discount.value = '5'
      const replaced = controller.itemDiscountSourcePresent(row)

      process.stdout.write(JSON.stringify({ blank, zero, cleared, replaced }))
    JAVASCRIPT

    expect(result).to eq(
      'blank' => true,
      'zero' => true,
      'cleared' => false,
      'replaced' => true
    )
  end

  it "updates explicit total wording only after a discount clear is confirmed" do
    result = run_controller_script(<<~JAVASCRIPT)
      ;(async () => {
      const mode = { value: 'explicit_line_total' }
      const discount = { value: '10', dataset: { originalDiscountRate: '10' } }
      const clearIntent = { value: '0' }
      const lineTotal = {
        value: '324',
        dataset: { originalLineTotal: '360', originalSavedLineTotal: '324' }
      }
      const explicit = {
        value: '900',
        dataset: {
          receiptFormLabelWithDiscount: '割引前明細金額',
          receiptFormLabelWithoutDiscount: '明細金額',
          receiptFormDecrementLabelWithDiscount: '割引前明細金額を減らす',
          receiptFormDecrementLabelWithoutDiscount: '明細金額を減らす',
          receiptFormIncrementLabelWithDiscount: '割引前明細金額を増やす',
          receiptFormIncrementLabelWithoutDiscount: '明細金額を増やす'
        },
        label: '',
        setAttribute (name, value) { if (name === 'aria-label') this.label = value },
        closest () { return explicitControl }
      }
      const decrementButton = {
        label: '',
        setAttribute (name, value) { if (name === 'aria-label') this.label = value }
      }
      const incrementButton = {
        label: '',
        setAttribute (name, value) { if (name === 'aria-label') this.label = value }
      }
      const explicitControl = {
        querySelector (selector) {
          if (selector.includes('decrement')) return decrementButton
          if (selector.includes('increment')) return incrementButton
          return null
        }
      }
      const help = {
        textContent: '',
        dataset: {
          receiptFormTextWithDiscount: '入力値に明細割引を1回適用',
          receiptFormTextWithoutDiscount: '印字された明細金額'
        }
      }
      const summary = {
        hidden: true,
        textContent: '',
        dataset: {
          receiptFormPricingModes: 'explicit_line_total',
          receiptFormSummaryTemplate: '割引前 %{amount}円',
          receiptFormSummaryUnset: '割引前明細金額',
          receiptFormSummaryTemplateWithDiscount: '割引前 %{amount}円',
          receiptFormSummaryTemplateWithoutDiscount: '明細金額 %{amount}円',
          receiptFormSummaryUnsetWithDiscount: '割引前明細金額',
          receiptFormSummaryUnsetWithoutDiscount: '明細金額'
        }
      }
      const targets = {
        pricingSourceModeInput: mode,
        discountRateInput: discount,
        clearItemDiscountBeforeExplicitInput: clearIntent,
        explicitLineTotalInput: explicit,
        explicitLineTotalHelp: help,
        lineTotalInput: lineTotal
      }
      const row = {
        dataset: { receiptFormActivePricingMode: 'reference_quantity_price', receiptFormHasPersistedAbsoluteDiscountSource: 'false' },
        querySelector (selector) {
          const match = selector.match(/receipt-form-target="([^"]+)"/)
          return match ? targets[match[1]] ?? null : null
        },
        querySelectorAll (selector) {
          if (selector.includes('pricingSourceSummary')) return [summary]
          return []
        }
      }
      mode.closest = () => row
      discount.closest = () => row
      const controller = Object.create(ReceiptFormController.prototype)
      Object.defineProperty(controller, 'discountRoundingModeValue', { value: 'round' })
      const answers = [false, true]
      controller.confirmPricingSourceDiscountClear = () => Promise.resolve(answers.shift())
      controller.recalculate = ({ pricingSourceChangedRow } = {}) => {
        const activeMode = controller.pricingSourceModeForRow(row)
        const originalLineTotal = activeMode === 'explicit_line_total' ? Number(explicit.value) : 360
        lineTotal.value = controller.lineTotalFor({
          originalLineTotal,
          discountRatePercent: controller.parseDiscountRateInput(discount.value),
          discountRateInput: discount,
          lineTotalInput: lineTotal,
          sourceModeChanged: pricingSourceChangedRow === row
        })
        controller.syncPricingSourceSummaryForRow(row, activeMode)
      }

      controller.syncExplicitLineTotalSemantics(row)
      const before = explicit.label
      await controller.pricingSourceModeChanged({ currentTarget: mode })
      const cancelled = {
        label: explicit.label, help: help.textContent, discount: discount.value, lineTotal: lineTotal.value
      }
      mode.value = 'explicit_line_total'
      await controller.pricingSourceModeChanged({ currentTarget: mode })
      const confirmed = {
        label: explicit.label,
        decrementLabel: decrementButton.label,
        incrementLabel: incrementButton.label,
        help: help.textContent,
        summary: summary.textContent,
        discount: discount.value,
        lineTotal: lineTotal.value
      }
      discount.value = '0'
      controller.discountRateChanged({ currentTarget: discount })
      const explicitZeroDiscount = {
        label: explicit.label,
        decrementLabel: decrementButton.label,
        incrementLabel: incrementButton.label,
        help: help.textContent,
        summary: summary.textContent,
        discount: discount.value,
        clearIntent: clearIntent.value,
        lineTotal: lineTotal.value
      }
      mode.value = 'reference_quantity_price'
      await controller.pricingSourceModeChanged({ currentTarget: mode })
      const restored = {
        label: explicit.label, help: help.textContent, discount: discount.value, lineTotal: lineTotal.value
      }

      process.stdout.write(JSON.stringify({ before, cancelled, confirmed, explicitZeroDiscount, restored }))
      })()
    JAVASCRIPT

    expect(result).to eq(
      "before" => "割引前明細金額",
      "cancelled" => {
        "label" => "割引前明細金額", "help" => "入力値に明細割引を1回適用",
        "discount" => "10", "lineTotal" => "324"
      },
      "confirmed" => {
        "label" => "明細金額", "decrementLabel" => "明細金額を減らす",
        "incrementLabel" => "明細金額を増やす", "help" => "印字された明細金額",
        "summary" => "明細金額 900円",
        "discount" => "", "lineTotal" => 900
      },
      "explicitZeroDiscount" => {
        "label" => "割引前明細金額",
        "decrementLabel" => "割引前明細金額を減らす",
        "incrementLabel" => "割引前明細金額を増やす",
        "help" => "入力値に明細割引を1回適用",
        "summary" => "割引前 900円",
        "discount" => "0",
        "clearIntent" => "1",
        "lineTotal" => 900
      },
      "restored" => {
        "label" => "割引前明細金額", "help" => "入力値に明細割引を1回適用",
        "discount" => "10", "lineTotal" => 324
      }
    )
  end

  it "stops an incompatible pricing preview without changing its source" do
    result = run_controller_script(<<~JAVASCRIPT)
      const runCase = (definition) => {
        const inputs = {
          pricingSourceModeInput: { value: definition.mode },
          quantityInput: { value: definition.quantity },
          quantityUnitInput: { value: definition.unit },
          priceInput: { value: definition.price },
          referencePriceAmountInput: { value: definition.referencePrice },
          referenceQuantityInput: { value: definition.referenceQuantity },
          referenceQuantityUnitInput: { value: definition.referenceUnit },
          referencePriceTaxInclusionInput: { value: 'gross' },
          discountRateInput: { value: '', dataset: { originalDiscountRate: '' } },
          taxRateInput: { value: '10' },
          lineTotalInput: { value: '777', dataset: { originalLineTotal: '777', originalSavedLineTotal: '777' } },
          originalLineTotalInput: { value: '777' }
        }
        const row = {
          dataset: { receiptFormActivePricingMode: definition.mode },
          querySelector (selector) {
            const match = selector.match(/receipt-form-target="([^"]+)"/)
            return match ? inputs[match[1]] ?? null : null
          },
          querySelectorAll () { return [] }
        }
        const controller = Object.create(ReceiptFormController.prototype)
        Object.defineProperties(controller, {
          itemRowTargets: { value: [row] },
          countableQuantityUnitsValue: { value: 'each,item,piece,bag,sheet,unit,box,set' },
          receiptItemPriceMaxValue: { value: 999999999 },
          receiptItemLineTotalMaxValue: { value: 999999999 },
          discountRoundingModeValue: { value: 'round' }
        })
        let unavailable = false
        controller.previewNumericInputsValid = () => true
        controller.previewRowExcluded = () => false
        controller.renderUnavailablePreview = () => { unavailable = true }
        controller.recalculate()

        return {
          unavailable,
          mode: inputs.pricingSourceModeInput.value,
          quantity: inputs.quantityInput.value,
          unit: inputs.quantityUnitInput.value,
          price: inputs.priceInput.value,
          referencePrice: inputs.referencePriceAmountInput.value,
          referenceQuantity: inputs.referenceQuantityInput.value,
          referenceUnit: inputs.referenceQuantityUnitInput.value,
          lineTotal: inputs.lineTotalInput.value
        }
      }

      process.stdout.write(JSON.stringify({
        countDimensionMismatch: runCase({
          mode: 'count_unit_price', quantity: '1.5', unit: 'kilogram', price: '100',
          referencePrice: '', referenceQuantity: '', referenceUnit: ''
        }),
        referenceDimensionMismatch: runCase({
          mode: 'reference_quantity_price', quantity: '1.5', unit: 'liter', price: '',
          referencePrice: '498', referenceQuantity: '100', referenceUnit: 'gram'
        }),
        referenceLineLimitExceeded: runCase({
          mode: 'reference_quantity_price', quantity: '2', unit: 'gram', price: '',
          referencePrice: '999999999', referenceQuantity: '1', referenceUnit: 'gram'
        })
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result.dig("countDimensionMismatch", "unavailable")).to be(true)
      expect(result.dig("referenceDimensionMismatch", "unavailable")).to be(true)
      expect(result.dig("referenceLineLimitExceeded", "unavailable")).to be(true)
      expect(result["countDimensionMismatch"]).to include(
        "mode" => "count_unit_price", "quantity" => "1.5", "unit" => "kilogram", "price" => "100",
        "lineTotal" => "777"
      )
      expect(result["referenceDimensionMismatch"]).to include(
        "mode" => "reference_quantity_price", "quantity" => "1.5", "unit" => "liter",
        "referencePrice" => "498", "referenceQuantity" => "100", "referenceUnit" => "gram",
        "lineTotal" => "777"
      )
      expect(result["referenceLineLimitExceeded"]).to include(
        "mode" => "reference_quantity_price", "quantity" => "2", "unit" => "gram",
        "referencePrice" => "999999999", "referenceQuantity" => "1", "referenceUnit" => "gram",
        "lineTotal" => "777"
      )
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

  it "matches the Amount Engine for gross and net reference price previews" do
    gross_item = {
      pricingSourceKind: "reference_quantity_price",
      referencePriceAmount: "120",
      referenceQuantity: "500",
      referenceQuantityUnit: "milliliter",
      referencePriceTaxInclusion: "gross",
      quantity: "1.5",
      quantityUnit: "liter",
      price: nil,
      originalLineTotal: 998,
      lineTotal: 997,
      taxRate: 10,
      discountRate: 10
    }
    net_item = gross_item.merge(referencePriceTaxInclusion: "net")

    gross = run_amount_round_trip(basis: "external", items: [ gross_item ])
    net = run_amount_round_trip(basis: "internal", items: [ net_item ])

    aggregate_failures do
      expect(gross["initial"]).to include(
        "subtotal" => 295,
        "tax" => 29,
        "total" => 324,
        "firstLineTotal" => 324
      )
      expect(net["initial"]).to include(
        "subtotal" => 324,
        "tax" => 32,
        "total" => 356,
        "firstLineTotal" => 324
      )
    end
  end

  it "projects mixed gross and net reference sources by item basis" do
    common = {
      pricingSourceKind: "reference_quantity_price",
      referencePriceAmount: "120",
      referenceQuantity: "500",
      referenceQuantityUnit: "milliliter",
      quantity: "1.5",
      quantityUnit: "liter",
      price: nil,
      originalLineTotal: nil,
      lineTotal: nil,
      taxRate: 10
    }
    items = [
      common.merge(referencePriceTaxInclusion: "gross"),
      common.merge(referencePriceTaxInclusion: "net")
    ]

    result = run_amount_round_trip(basis: "internal", items:)

    expect(result["initial"]).to include(
      "subtotal" => 688,
      "tax" => 68,
      "total" => 756,
      "firstLineTotal" => 360
    )
  end

  it "rejects source item and receipt aggregate values above configured limits without clamping" do
    count_over_limit = run_amount_round_trip(
      basis: "internal",
      items: [
        {
          pricingSourceKind: "count_unit_price",
          quantity: 2,
          quantityUnit: "each",
          price: 100,
          lineTotal: 100,
          originalLineTotal: 200,
          taxRate: 0,
          discountRate: 50
        }
      ],
      item_line_total_max: 100,
      receipt_total_max: 200,
      capture_preview_unavailable: true
    )
    projected_net_within_receipt_limit = run_amount_round_trip(
      basis: "external",
      items: [
        {
          pricingSourceKind: "reference_quantity_price",
          referencePriceAmount: 100,
          referenceQuantity: 1,
          referenceQuantityUnit: "each",
          referencePriceTaxInclusion: "net",
          quantity: 1,
          quantityUnit: "each",
          price: nil,
          lineTotal: 100,
          originalLineTotal: 100,
          taxRate: 10
        }
      ],
      item_line_total_max: 100,
      receipt_total_max: 200,
      capture_preview_unavailable: true
    )
    aggregate_over_limit = run_amount_round_trip(
      basis: "internal",
      items: [
        { pricingSourceKind: "count_unit_price", quantity: 1, quantityUnit: "each", price: 60, lineTotal: 60, taxRate: 0 },
        { pricingSourceKind: "count_unit_price", quantity: 1, quantityUnit: "each", price: 60, lineTotal: 60, taxRate: 0 }
      ],
      item_line_total_max: 100,
      receipt_total_max: 100,
      capture_preview_unavailable: true
    )
    exact_limits = run_amount_round_trip(
      basis: "internal",
      items: [
        { pricingSourceKind: "count_unit_price", quantity: 1, quantityUnit: "each", price: 100, lineTotal: 100, taxRate: 0 }
      ],
      item_line_total_max: 100,
      receipt_total_max: 100,
      capture_preview_unavailable: true
    )

    aggregate_failures do
      expect(count_over_limit.dig("initial", "previewUnavailable")).to be(true)
      expect(projected_net_within_receipt_limit["initial"]).to include(
        "subtotal" => 100,
        "tax" => 10,
        "total" => 110,
        "previewUnavailable" => false
      )
      expect(aggregate_over_limit.dig("initial", "previewUnavailable")).to be(true)
      expect(exact_limits["initial"]).to include(
        "subtotal" => 100,
        "tax" => 0,
        "total" => 100,
        "previewUnavailable" => false
      )
    end
  end

  it "uses the trusted form fallback only for reference net rows with a blank item tax rate" do
    reference_item = {
      pricingSourceKind: "reference_quantity_price",
      referencePriceAmount: 100,
      referenceQuantity: 1,
      referenceQuantityUnit: "each",
      referencePriceTaxInclusion: "net",
      quantity: 1,
      quantityUnit: "each",
      price: nil,
      lineTotal: 100,
      originalLineTotal: 100,
      taxRate: nil
    }
    trusted_fallback = run_amount_round_trip(
      basis: "internal",
      items: [ reference_item ],
      reference_projection_fallback_tax_rate: "10",
      capture_preview_unavailable: true
    )
    no_fallback = run_amount_round_trip(
      basis: "internal",
      items: [ reference_item ],
      capture_preview_unavailable: true
    )
    explicit_zero = run_amount_round_trip(
      basis: "internal",
      items: [ reference_item.merge(taxRate: 0) ],
      reference_projection_fallback_tax_rate: "10",
      capture_preview_unavailable: true
    )
    source_changed = run_amount_round_trip(
      basis: "internal",
      items: [ reference_item ],
      reference_projection_fallback_tax_rate: "10",
      changed_reference_price: 110,
      capture_preview_unavailable: true
    )
    explicit_rate_after_source_change = run_amount_round_trip(
      basis: "internal",
      items: [ reference_item.merge(taxRate: 0) ],
      reference_projection_fallback_tax_rate: "10",
      changed_reference_price: 110,
      capture_preview_unavailable: true
    )

    aggregate_failures do
      expect(trusted_fallback["initial"]).to include(
        "subtotal" => 100,
        "tax" => 10,
        "total" => 110,
        "previewUnavailable" => false
      )
      expect(no_fallback.dig("initial", "previewUnavailable")).to be(true)
      expect(explicit_zero["initial"]).to include(
        "subtotal" => 100,
        "tax" => 0,
        "total" => 100,
        "previewUnavailable" => false
      )
      expect(source_changed.dig("doubled", "previewUnavailable")).to be(true)
      expect(explicit_rate_after_source_change["doubled"]).to include(
        "subtotal" => 110,
        "tax" => 0,
        "total" => 110,
        "previewUnavailable" => false
      )
    end
  end

  it "treats an explicit total as the gross pre-discount authority" do
    result = run_amount_round_trip(
      basis: "external",
      items: [
        {
          pricingSourceKind: "explicit_line_total",
          explicitLineTotal: "1000",
          quantity: "1.5",
          quantityUnit: "liter",
          price: nil,
          originalLineTotal: 360,
          lineTotal: 324,
          taxRate: 10,
          discountRate: 10,
          captureOriginalLineTotal: true
        }
      ]
    )

    expect(result["initial"]).to include(
      "sourceOriginalLineTotal" => 1_000,
      "firstLineTotal" => 900,
      "subtotal" => 819,
      "tax" => 81,
      "total" => 900
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

  it "inherits a safe single item tax rate for a blank purchase adjustment like the Amount Engine" do
    items = [ { price: 100, lineTotal: 100, taxRate: 10 } ]
    adjustments = [ { amount: 10, taxRate: nil, effect: "purchase_adjustment", sign: "surcharge" } ]

    internal = run_amount_round_trip(basis: "internal", items:, adjustments:)
    external = run_amount_round_trip(basis: "external", items:, adjustments:)
    incompatible = run_amount_round_trip(
      basis: "external",
      items:,
      adjustments:,
      adjustment_tax_detail_rates: [ 8 ]
    )

    aggregate_failures do
      expect(internal["initial"]).to include("subtotal" => 100, "tax" => 10, "total" => 110)
      expect(internal["doubled"]).to include("subtotal" => 191, "tax" => 19, "total" => 210)
      expect(internal["restored"]).to eq(internal["initial"])
      expect(external["initial"]).to include("subtotal" => 110, "tax" => 11, "total" => 121)
      expect(external["doubled"]).to include("subtotal" => 210, "tax" => 21, "total" => 231)
      expect(external["restored"]).to eq(external["initial"])
      expect(incompatible["initial"]).to include("subtotal" => 110, "tax" => 10, "total" => 120)
    end
  end

  it "drops stale tax-detail evidence after a purchase input changes" do
    result = run_amount_round_trip(
      basis: "external",
      items: [ { price: 7, lineTotal: 7, taxRate: 8 } ],
      adjustments: [ { amount: 7, taxRate: nil, effect: "purchase_adjustment", sign: "surcharge" } ],
      adjustment_tax_detail_rates: [ 8 ],
      changed_first_tax_rate: 10
    )

    aggregate_failures do
      expect(result["initial"]).to include("subtotal" => 14, "tax" => 1, "total" => 15)
      expect(result["restored"]).to eq(result["initial"])
      expect(result["changedFirstTaxRate"]).to include("subtotal" => 14, "tax" => 1, "total" => 15)
    end
  end

  it "drops stored tax-detail rates when the Amount Engine rejects their numeric evidence" do
    result = run_amount_round_trip(
      basis: "external",
      items: [ { price: 100, lineTotal: 100, taxRate: 10 } ],
      adjustments: [ { amount: 10, taxRate: nil, effect: "purchase_adjustment", sign: "surcharge" } ],
      adjustment_tax_detail_rates: [ 8 ],
      adjustment_tax_detail_evidence_stale: true
    )

    aggregate_failures do
      expect(result["initial"]).to include("subtotal" => 110, "tax" => 11, "total" => 121)
      expect(result["restored"]).to eq(result["initial"])
    end
  end

  it "drops stored tax-detail rates on the initial preview after a failed changed purchase submission" do
    result = run_amount_round_trip(
      basis: "external",
      items: [ { price: 100, lineTotal: 100, taxRate: 10 } ],
      adjustments: [ { amount: 10, taxRate: nil, effect: "purchase_adjustment", sign: "surcharge" } ],
      adjustment_tax_detail_rates: [ 8 ],
      purchase_inputs_changed: true
    )

    aggregate_failures do
      expect(result["initial"]).to include("subtotal" => 110, "tax" => 11, "total" => 121)
      expect(result["restored"]).to eq(result["initial"])
    end
  end

  it "restores the persisted line total when a discount rate is changed and returned" do
    without_initial_discount = run_amount_round_trip(
      basis: "external",
      items: [ { price: 1_000, originalLineTotal: 1_000, lineTotal: 1_000, taxRate: 10, discountRate: nil } ],
      changed_discount_rate: 10
    )
    with_initial_discount = run_amount_round_trip(
      basis: "external",
      items: [ { price: 1_000, originalLineTotal: 1_000, lineTotal: 900, taxRate: 10, discountRate: 10 } ],
      changed_discount_rate: 20
    )

    aggregate_failures do
      expect(without_initial_discount).to eq(
        "initial" => { "subtotal" => 1_000, "tax" => 100, "total" => 1_100, "firstLineTotal" => 1_000 },
        "doubled" => { "subtotal" => 900, "tax" => 90, "total" => 990, "firstLineTotal" => 900 },
        "restored" => { "subtotal" => 1_000, "tax" => 100, "total" => 1_100, "firstLineTotal" => 1_000 }
      )
      expect(with_initial_discount).to eq(
        "initial" => { "subtotal" => 900, "tax" => 90, "total" => 990, "firstLineTotal" => 900 },
        "doubled" => { "subtotal" => 800, "tax" => 80, "total" => 880, "firstLineTotal" => 800 },
        "restored" => { "subtotal" => 900, "tax" => 90, "total" => 990, "firstLineTotal" => 900 }
      )
    end
  end

  it "preserves an explicit countable line total when price is blank" do
    quantity_result = run_amount_round_trip(
      basis: "internal",
      items: [ { price: nil, originalLineTotal: 500, lineTotal: 500, taxRate: 0 } ]
    )
    price_result = run_amount_round_trip(
      basis: "internal",
      items: [ { price: nil, originalLineTotal: 500, lineTotal: 500, taxRate: 0 } ],
      changed_price: 100
    )

    aggregate_failures do
      expect(quantity_result).to eq(
        "initial" => { "subtotal" => 500, "tax" => 0, "total" => 500, "firstLineTotal" => 500 },
        "doubled" => { "subtotal" => 500, "tax" => 0, "total" => 500, "firstLineTotal" => 500 },
        "restored" => { "subtotal" => 500, "tax" => 0, "total" => 500, "firstLineTotal" => 500 }
      )
      expect(price_result).to eq(
        "initial" => { "subtotal" => 500, "tax" => 0, "total" => 500, "firstLineTotal" => 500 },
        "doubled" => { "subtotal" => 100, "tax" => 0, "total" => 100, "firstLineTotal" => 100 },
        "restored" => { "subtotal" => 500, "tax" => 0, "total" => 500, "firstLineTotal" => 500 }
      )
    end
  end

  it "keeps amountless placeholder source fields blank while quantity changes" do
    quantity_result = run_amount_round_trip(
      basis: "external",
      items: [
        {
          price: nil,
          originalLineTotal: nil,
          lineTotal: nil,
          taxRate: 0,
          captureBlankSources: true
        }
      ],
      initial_receipt_amounts: { subtotal: 91, tax: 9, total: 100 }
    )
    price_result = run_amount_round_trip(
      basis: "external",
      items: [
        {
          price: nil,
          originalLineTotal: nil,
          lineTotal: nil,
          taxRate: 0,
          captureBlankSources: true
        }
      ],
      initial_receipt_amounts: { subtotal: 91, tax: 9, total: 100 },
      changed_price: 100
    )
    blank_adjustment_result = run_amount_round_trip(
      basis: "external",
      items: [
        {
          price: nil,
          originalLineTotal: nil,
          lineTotal: nil,
          taxRate: 0,
          captureBlankSources: true
        }
      ],
      adjustments: [
        { amount: nil, taxRate: nil, effect: "purchase_adjustment", sign: "discount" }
      ],
      initial_receipt_amounts: { subtotal: 91, tax: 9, total: 100 },
      add_blank_adjustment_after_initial: true
    )
    tax_summary_result = run_amount_round_trip(
      basis: "external",
      items: [
        {
          price: nil,
          originalLineTotal: nil,
          lineTotal: nil,
          taxRate: 0,
          captureBlankSources: true
        }
      ],
      initial_receipt_amounts: { subtotal: 91, tax: 9, total: 100 },
      initial_tax_rate_summary: "10%"
    )
    purchase_adjustment_result = run_amount_round_trip(
      basis: "external",
      items: [ { price: nil, originalLineTotal: nil, lineTotal: nil, taxRate: 0 } ],
      adjustments: [
        { amount: 10, taxRate: 10, effect: "purchase_adjustment", sign: "surcharge" }
      ],
      initial_receipt_amounts: { subtotal: 91, tax: 9, total: 100 }
    )
    payment_adjustment_result = run_amount_round_trip(
      basis: "external",
      items: [ { price: nil, originalLineTotal: nil, lineTotal: nil, taxRate: 0 } ],
      adjustments: [
        { amount: 10, taxRate: nil, effect: "payment_adjustment", sign: "discount" }
      ],
      initial_receipt_amounts: { subtotal: 91, tax: 9, total: 100 }
    )
    explicit_zero_result = run_amount_round_trip(
      basis: "external",
      items: [ { price: nil, originalLineTotal: nil, lineTotal: nil, taxRate: 0 } ],
      initial_receipt_amounts: { subtotal: 91, tax: 9, total: 100 },
      changed_price: 0
    )
    corrected_after_422_result = run_amount_round_trip(
      basis: "external",
      items: [ { price: nil, originalLineTotal: nil, lineTotal: nil, taxRate: 0 } ],
      initial_receipt_amounts: { subtotal: 91, tax: 9, total: 100 },
      purchase_inputs_changed: true,
      purchase_input_baseline_trusted: true
    )

    expected = {
      "subtotal" => 91,
      "tax" => 9,
      "total" => 100,
      "firstLineTotal" => nil,
      "sourceLineTotal" => "",
      "sourceOriginalLineTotal" => ""
    }
    aggregate_failures do
      expect(quantity_result).to eq(
        "initial" => expected,
        "doubled" => expected,
        "restored" => expected
      )
      expect(price_result).to eq(
        "initial" => expected,
        "doubled" => {
          "subtotal" => 100,
          "tax" => 0,
          "total" => 100,
          "firstLineTotal" => 100,
          "sourceLineTotal" => "100",
          "sourceOriginalLineTotal" => "100"
        },
        "restored" => expected
      )
      expect(blank_adjustment_result["initial"]).to include(
        "subtotal" => 91,
        "tax" => 9,
        "total" => 100,
        "sourceLineTotal" => "",
        "sourceOriginalLineTotal" => ""
      )
      expect(tax_summary_result.values).to all(include("taxRateSummary" => "10%"))
      expect(purchase_adjustment_result["initial"]).to include(
        "subtotal" => 91,
        "tax" => 9,
        "total" => 100,
        "paymentAdjustmentTotal" => 0,
        "finalPaymentTotal" => 100
      )
      expect(payment_adjustment_result["initial"]).to include(
        "subtotal" => 91,
        "tax" => 9,
        "total" => 100,
        "paymentAdjustmentTotal" => -10,
        "finalPaymentTotal" => 90
      )
      expect(explicit_zero_result["doubled"]).to include(
        "subtotal" => 0,
        "tax" => 0,
        "total" => 0,
        "firstLineTotal" => 0
      )
      expect(explicit_zero_result["restored"]).to include(
        "subtotal" => 91,
        "tax" => 9,
        "total" => 100
      )
      expect(corrected_after_422_result.values).to all(include(
        "subtotal" => 91,
        "tax" => 9,
        "total" => 100
      ))
    end
  end

  it "keeps missing line displays unset through quantity changes and clearing an entered zero" do
    missing_item = { price: nil, lineTotal: nil, originalLineTotal: nil, taxRate: 0, captureBlankSources: true }
    quantity_result = run_amount_round_trip(
      basis: "internal",
      items: [ missing_item ],
      initial_receipt_amounts: { subtotal: 100, tax: 0, total: 100 },
      capture_line_displays: true
    )
    price_result = run_amount_round_trip(
      basis: "internal",
      items: [ missing_item ],
      initial_receipt_amounts: { subtotal: 100, tax: 0, total: 100 },
      changed_price: 0,
      capture_line_displays: true
    )
    missing_display = { "text" => "Unset", "title" => "Unset", "amount" => nil }
    missing_state = {
      "firstLineTotal" => nil,
      "sourceLineTotal" => "",
      "sourceOriginalLineTotal" => "",
      "lineDisplays" => [ [ missing_display, missing_display ] ]
    }

    aggregate_failures do
      expect(quantity_result.values).to all(include(missing_state))
      expect(price_result["initial"]).to include(missing_state)
      expect(price_result["restored"]).to include(missing_state)
      expect(price_result["doubled"]).to include(
        "firstLineTotal" => 0,
        "sourceLineTotal" => "0",
        "sourceOriginalLineTotal" => "0",
        "lineDisplays" => [
          [
            { "text" => "¥0", "title" => "¥0", "amount" => "0" },
            { "text" => "Subtotal ¥0", "title" => "Subtotal ¥0", "amount" => "0" }
          ]
        ]
      )
    end
  end

  it "keeps missing line displays unset when reference items trigger initial mixed-mode previews" do
    result = run_amount_round_trip(
      basis: "internal",
      items: [
        { price: nil, lineTotal: nil, originalLineTotal: nil, taxRate: 0, captureBlankSources: true },
        { pricingSourceKind: "count_unit_price", price: 200, quantity: 1, lineTotal: 200, taxRate: 0 },
        {
          pricingSourceKind: "reference_quantity_price",
          price: nil,
          referencePriceAmount: 150,
          referenceQuantity: 100,
          referenceQuantityUnit: "gram",
          referencePriceTaxInclusion: "gross",
          quantity: 200,
          quantityUnit: "gram",
          lineTotal: 300,
          taxRate: 0
        },
        { pricingSourceKind: "explicit_line_total", price: nil, explicitLineTotal: 0, lineTotal: 0, taxRate: 0 }
      ],
      capture_line_displays: true,
      sync_initial_pricing_previews: true
    )
    missing_display = { "text" => "Unset", "title" => "Unset", "amount" => nil }
    expected_displays = [ [ missing_display, missing_display ] ] + [ 200, 300, 0 ].map do |amount|
      [
        { "text" => "¥#{amount}", "title" => "¥#{amount}", "amount" => amount.to_s },
        { "text" => "Subtotal ¥#{amount}", "title" => "Subtotal ¥#{amount}", "amount" => amount.to_s }
      ]
    end

    expect(result.values).to all(include(
      "total" => 500,
      "firstLineTotal" => nil,
      "sourceLineTotal" => "",
      "sourceOriginalLineTotal" => "",
      "lineDisplays" => expected_displays
    ))
  end

  it "keeps complete zero and fully discounted formula line displays numeric" do
    count_item = { pricingSourceKind: "count_unit_price", price: 0, quantity: 1, taxRate: 0 }
    reference_item = {
      pricingSourceKind: "reference_quantity_price",
      price: nil,
      referencePriceAmount: 0,
      referenceQuantity: 100,
      referenceQuantityUnit: "gram",
      referencePriceTaxInclusion: "gross",
      quantity: 100,
      quantityUnit: "gram",
      taxRate: 0
    }
    explicit_item = { pricingSourceKind: "explicit_line_total", price: nil, explicitLineTotal: 0, taxRate: 0 }
    definitions = [
      count_item,
      count_item.merge(price: 125, discountRate: 100),
      reference_item,
      reference_item.merge(referencePriceAmount: 125, discountRate: 100),
      explicit_item
    ]

    aggregate_failures do
      definitions.each do |item|
        result = run_amount_round_trip(basis: "internal", items: [ item ], capture_line_displays: true)
        expect(result.values).to all(include(
          "firstLineTotal" => 0,
          "lineDisplays" => [
            [
              { "text" => "¥0", "title" => "¥0", "amount" => "0" },
              { "text" => "Subtotal ¥0", "title" => "Subtotal ¥0", "amount" => "0" }
            ]
          ]
        ))
      end
    end
  end

  it "uses the trusted pre-submit fingerprint after a 422 correction" do
    result = run_controller_script(<<~JAVASCRIPT)
      const baseline = JSON.stringify({ items: [], adjustments: [] })
      const hiddenBaseline = { value: baseline }
      const controller = Object.create(ReceiptFormController.prototype)
      Object.defineProperties(controller, {
        element: { value: { dataset: {} } },
        purchaseInputsChangedValue: { value: true },
        hasInitialPurchaseInputFingerprintTarget: { value: true },
        initialPurchaseInputFingerprintTarget: { value: hiddenBaseline }
      })
      controller.purchaseInputFingerprint = () => baseline

      controller.captureInitialPurchaseInputFingerprint()

      process.stdout.write(JSON.stringify({
        initial: controller.initialPurchaseInputFingerprint,
        trusted: controller.purchaseInputBaselineTrusted,
        changed: controller.purchaseInputsChangedForPreview(),
        hidden: hiddenBaseline.value
      }))
    JAVASCRIPT

    expect(result).to eq(
      "initial" => '{"items":[],"adjustments":[]}',
      "trusted" => true,
      "changed" => false,
      "hidden" => '{"items":[],"adjustments":[]}'
    )
  end

  it "keeps the initial receipt amount snapshot across Turbo reconnects" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(ReceiptFormController.prototype)
      const element = { dataset: {} }
      const subtotal = { textContent: '¥91', dataset: {} }
      const tax = { textContent: '¥9', dataset: {} }
      const total = { textContent: '¥100', dataset: {} }
      const taxRateSummary = { textContent: '10%' }
      Object.defineProperties(controller, {
        element: { value: element },
        hasSubtotalAmountTarget: { value: true },
        subtotalAmountTarget: { value: subtotal },
        hasTaxAmountTarget: { value: true },
        taxAmountTarget: { value: tax },
        hasTotalAmountTarget: { value: true },
        totalAmountTarget: { value: total },
        hasTaxRateSummaryTarget: { value: true },
        taxRateSummaryTarget: { value: taxRateSummary },
        receiptTotalAmountMaxValue: { value: 999999999 },
        receiptTaxAmountMaxValue: { value: 999999999 }
      })

      controller.captureInitialReceiptAmounts()
      const first = controller.initialReceiptAmounts
      subtotal.textContent = '¥0'
      tax.textContent = '¥0'
      total.textContent = '¥0'
      controller.captureInitialReceiptAmounts()

      process.stdout.write(JSON.stringify({ first, reconnected: controller.initialReceiptAmounts }))
    JAVASCRIPT

    expect(result).to eq(
      "first" => { "subtotal" => 91, "tax" => 9, "total" => 100, "taxRateSummary" => "10%" },
      "reconnected" => { "subtotal" => 91, "tax" => 9, "total" => 100, "taxRateSummary" => "10%" }
    )
  end

  it "keeps nullable receipt amounts distinct from zero through capture and Turbo reconnect" do
    result = run_controller_script(<<~JAVASCRIPT)
      const capture = (values) => {
        const controller = Object.create(ReceiptFormController.prototype)
        const targets = values.map((value) => ({ textContent: value, dataset: {} }))
        Object.defineProperties(controller, {
          element: { value: { dataset: {} } },
          hasSubtotalAmountTarget: { value: true },
          subtotalAmountTarget: { value: targets[0] },
          hasTaxAmountTarget: { value: true },
          taxAmountTarget: { value: targets[1] },
          hasTotalAmountTarget: { value: true },
          totalAmountTarget: { value: targets[2] },
          hasTaxRateSummaryTarget: { value: false },
          receiptTotalAmountMaxValue: { value: 999999999 },
          receiptTaxAmountMaxValue: { value: 999999999 }
        })
        controller.captureInitialReceiptAmounts()
        const first = controller.initialReceiptAmounts
        targets.forEach((target) => { target.textContent = '¥0' })
        controller.captureInitialReceiptAmounts()
        return { first, reconnected: controller.initialReceiptAmounts }
      }

      process.stdout.write(JSON.stringify({
        missing: capture(['—', '', '—']),
        partial: capture(['¥91', '—', '¥100']),
        zero: capture(['¥0', '¥0', '¥0'])
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["missing"].values).to all(eq("subtotal" => nil, "tax" => nil, "total" => nil, "taxRateSummary" => nil))
      expect(result["partial"].values).to all(eq("subtotal" => 91, "tax" => nil, "total" => 100, "taxRateSummary" => nil))
      expect(result["zero"].values).to all(eq("subtotal" => 0, "tax" => 0, "total" => 0, "taxRateSummary" => nil))
    end
  end

  it "accepts bounded nullable receipt snapshots but rejects malformed and out-of-bound values" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(ReceiptFormController.prototype)
      Object.defineProperties(controller, {
        receiptTotalAmountMaxValue: { value: 100 },
        receiptTaxAmountMaxValue: { value: 20 }
      })
      const baseline = { subtotal: 80, tax: 20, total: 100 }
      process.stdout.write(JSON.stringify({
        complete: controller.validReceiptAmounts(baseline),
        nullable: controller.validReceiptAmounts({ subtotal: null, tax: null, total: null }),
        zero: controller.validReceiptAmounts({ subtotal: 0, tax: 0, total: 0 }),
        invalid: [
          {}, [], null,
          { ...baseline, subtotal: undefined },
          { ...baseline, total: '100' },
          { ...baseline, total: Number.NaN },
          { ...baseline, total: Number.POSITIVE_INFINITY },
          { ...baseline, total: -1 },
          { ...baseline, total: 101 },
          { ...baseline, subtotal: 101 },
          { ...baseline, tax: 21 }
        ].map((amounts) => Boolean(controller.validReceiptAmounts(amounts)))
      }))
    JAVASCRIPT

    expect(result).to eq("complete" => true, "nullable" => true, "zero" => true, "invalid" => Array.new(11, false))
  end

  it "keeps unknown receipt totals through quantity-only edits and restores them after clearing a zero source" do
    missing_item = { price: nil, originalLineTotal: nil, lineTotal: nil, taxRate: 0 }
    aggregate_failures do
      [ { subtotal: nil, tax: nil, total: nil }, { subtotal: 91, tax: nil, total: 100 } ].each do |amounts|
        quantity_result = run_amount_round_trip(basis: "internal", items: [ missing_item ], initial_receipt_amounts: amounts)
        source_result = run_amount_round_trip(
          basis: "internal",
          items: [ missing_item ],
          initial_receipt_amounts: amounts,
          changed_price: 0
        )
        expected = amounts.stringify_keys.merge("firstLineTotal" => nil)

        expect(quantity_result.values).to all(eq(expected))
        expect(source_result["initial"]).to eq(expected)
        expect(source_result["restored"]).to eq(expected)
        expect(source_result["doubled"]).to eq("subtotal" => 0, "tax" => 0, "total" => 0, "firstLineTotal" => 0)
      end
    end
  end

  it "keeps final payment unknown when only a payment adjustment is known" do
    result = run_amount_round_trip(
      basis: "internal",
      items: [ { price: nil, originalLineTotal: nil, lineTotal: nil, taxRate: 0 } ],
      adjustments: [ { amount: 10, taxRate: nil, effect: "payment_adjustment", sign: "discount" } ],
      initial_receipt_amounts: { subtotal: nil, tax: nil, total: nil }
    )

    expect(result.values).to all(include(
      "subtotal" => nil, "tax" => nil, "total" => nil,
      "paymentAdjustmentTotal" => -10, "finalPaymentTotal" => nil
    ))
  end

  it "renders an unknown amount without converting it to an animated zero" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(ReceiptFormController.prototype)
      const target = { textContent: '¥0', title: '¥0', dataset: { amountValue: '0' }, amountDisplayValue: 0 }
      Object.defineProperty(controller, 'unsetLabelValue', { value: 'Unset' })
      controller.shouldRenderAmountImmediately = () => true
      controller.syncPaymentSummaryLayout = () => {}
      controller.animateAmount(target, null)

      process.stdout.write(JSON.stringify({
        text: target.textContent,
        title: target.title,
        amount: target.dataset.amountValue ?? null,
        nullableValue: controller.currentAmountValue(target, null),
        animationBaseline: controller.currentAmountValue(target)
      }))
    JAVASCRIPT

    expect(result).to eq("text" => "Unset", "title" => "Unset", "amount" => nil, "nullableValue" => nil, "animationBaseline" => 0)
  end

  it "drops a transient countable working source before switching to a measurement unit" do
    result = run_amount_round_trip(
      basis: "internal",
      items: [
        {
          price: nil,
          originalLineTotal: 500,
          lineTotal: 500,
          taxRate: 0,
          captureOriginalLineTotal: true
        }
      ],
      changed_discount_rate: 10,
      changed_price_before_discount: 100,
      changed_quantity_unit: "kilogram"
    )

    expect(result["discounted"]).to eq(
      "subtotal" => 450,
      "tax" => 0,
      "total" => 450,
      "firstLineTotal" => 450,
      "sourceOriginalLineTotal" => 500
    )
  end

  it "restores the submitted pre-discount source after a transient countable price" do
    result = run_amount_round_trip(
      basis: "internal",
      items: [
        {
          price: nil,
          originalLineTotal: 500,
          lineTotal: 500,
          taxRate: 0,
          captureOriginalLineTotal: true
        }
      ],
      changed_discount_rate: 10,
      changed_price_before_discount: 100
    )

    expect(result).to eq(
      "initial" => {
        "subtotal" => 500,
        "tax" => 0,
        "total" => 500,
        "firstLineTotal" => 500,
        "sourceOriginalLineTotal" => 500
      },
      "priceEntered" => {
        "subtotal" => 100,
        "tax" => 0,
        "total" => 100,
        "firstLineTotal" => 100,
        "sourceOriginalLineTotal" => 100
      },
      "priceRestored" => {
        "subtotal" => 500,
        "tax" => 0,
        "total" => 500,
        "firstLineTotal" => 500,
        "sourceOriginalLineTotal" => 500
      },
      "discounted" => {
        "subtotal" => 450,
        "tax" => 0,
        "total" => 450,
        "firstLineTotal" => 450,
        "sourceOriginalLineTotal" => 500
      }
    )
  end

  it "submits the current pre-discount source after changing a countable item to measurement" do
    result = run_amount_round_trip(
      basis: "internal",
      items: [
        {
          price: 100,
          quantity: 2,
          originalLineTotal: 0,
          lineTotal: 0,
          taxRate: 0,
          captureOriginalLineTotal: true
        }
      ],
      changed_discount_rate: 10,
      changed_quantity_unit: "kilogram"
    )

    expect(result).to eq(
      "initial" => {
        "subtotal" => 200,
        "tax" => 0,
        "total" => 200,
        "firstLineTotal" => 200,
        "sourceOriginalLineTotal" => 200
      },
      "doubled" => {
        "subtotal" => 180,
        "tax" => 0,
        "total" => 180,
        "firstLineTotal" => 180,
        "sourceOriginalLineTotal" => 200
      },
      "restored" => {
        "subtotal" => 200,
        "tax" => 0,
        "total" => 200,
        "firstLineTotal" => 200,
        "sourceOriginalLineTotal" => 200
      }
    )
  end

  it "uses the server adjustment classification contract after a label change" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(ReceiptFormController.prototype)
      Object.defineProperties(controller, {
        adjustmentPaymentKindsValue: { value: 'point_usage' },
        adjustmentPurchaseKindsValue: { value: 'service_charge,late_night_charge,delivery_fee,bag_fee,handling_fee,coupon,return_refund' },
        adjustmentPaymentLabelPatternValue: { value: 'キャッシュレス|cashless|payment\\s*discount' }
      })
      const input = (value) => ({ value })
      const row = ({ kind, label, effect, sourcePayment = false, sourceNonManual = false }) => {
        const kindInput = input(kind)
        const labelInput = input(label)
        return {
          dataset: {
            receiptFormAdjustmentEffect: effect,
            receiptFormAdjustmentSourcePayment: String(sourcePayment),
            receiptFormAdjustmentSourceNonManual: String(sourceNonManual)
          },
          kindInput,
          labelInput,
          querySelector (selector) {
            if (selector.includes('adjustmentKindInput')) return kindInput
            if (selector.includes('[label]')) return labelInput
            return null
          }
        }
      }

      const labelOnly = row({ kind: 'receipt_discount', label: '通常値引き', effect: 'purchase_adjustment' })
      const sourceOnly = row({ kind: 'receipt_discount', label: '還元額', effect: 'payment_adjustment', sourcePayment: true })
      const explicitPurchase = row({ kind: 'coupon', label: 'キャッシュレス還元', effect: 'purchase_adjustment', sourcePayment: true })
      const labelInitiallyPayment = row({
        kind: 'receipt_discount',
        label: 'キャッシュレス還元',
        effect: 'payment_adjustment'
      })
      const nonManual = row({
        kind: 'receipt_discount',
        label: '通常値引き',
        effect: 'purchase_adjustment',
        sourceNonManual: true
      })
      const snapshots = [controller.adjustmentEffectForRow(labelOnly)]
      labelOnly.labelInput.value = 'キャッシュレス還元'
      snapshots.push(controller.adjustmentEffectForRow(labelOnly))
      labelOnly.labelInput.value = '通常値引き'
      snapshots.push(controller.adjustmentEffectForRow(labelOnly))
      labelInitiallyPayment.labelInput.value = '通常値引き'
      nonManual.kindInput.value = 'other'
      const nonManualOther = controller.adjustmentEffectForRow(nonManual)
      nonManual.kindInput.value = 'receipt_discount'

      process.stdout.write(JSON.stringify({
        labelOnly: snapshots,
        sourceOnly: controller.adjustmentEffectForRow(sourceOnly),
        explicitPurchase: controller.adjustmentEffectForRow(explicitPurchase),
        labelInitiallyPayment: controller.adjustmentEffectForRow(labelInitiallyPayment),
        nonManualOther,
        nonManualReceiptDiscount: controller.adjustmentEffectForRow(nonManual)
      }))
    JAVASCRIPT

    expect(result).to eq(
      "labelOnly" => %w[purchase_adjustment payment_adjustment purchase_adjustment],
      "sourceOnly" => "payment_adjustment",
      "explicitPurchase" => "purchase_adjustment",
      "labelInitiallyPayment" => "purchase_adjustment",
      "nonManualOther" => "unknown_adjustment",
      "nonManualReceiptDiscount" => "purchase_adjustment"
    )
  end

  it "uses the Amount Engine nonnegative draft when a purchase candidate contains a negative amount" do
    items = [
      { price: 100, lineTotal: 100, taxRate: 10 },
      { price: 100, lineTotal: 100, taxRate: 8 }
    ]
    adjustments = [
      { amount: 190, taxRate: 10, effect: "purchase_adjustment", sign: "discount" }
    ]

    internal = run_amount_round_trip(basis: "internal", items:, adjustments:)
    external = run_amount_round_trip(basis: "external", items:, adjustments:)

    aggregate_failures do
      expect(internal["initial"]).to include("subtotal" => 0, "tax" => 0, "total" => 0)
      expect(internal["restored"]).to eq(internal["initial"])
      expect(external["initial"]).to include("subtotal" => 0, "tax" => 0, "total" => 0)
      expect(external["restored"]).to eq(external["initial"])
    end
  end

  it "keeps the raw negative candidate when deriving final payment for server-side review" do
    result = run_amount_round_trip(
      basis: "internal",
      items: [ { price: 100, lineTotal: 100, taxRate: 0 } ],
      adjustments: [
        { amount: 200, taxRate: 0, effect: "purchase_adjustment", sign: "discount" },
        { amount: 10, taxRate: 0, effect: "payment_adjustment", sign: "discount" }
      ]
    )

    expect(result["initial"]).to include(
      "subtotal" => 0,
      "tax" => 0,
      "total" => 0,
      "paymentAdjustmentTotal" => -10,
      "finalPaymentTotal" => -110
    )
  end

  it "preserves a negative final payment amount for server-side review" do
    result = run_amount_round_trip(
      basis: "internal",
      items: [ { price: 100, lineTotal: 100, taxRate: 0 } ],
      adjustments: [ { amount: 200, taxRate: 0, effect: "payment_adjustment", sign: "discount" } ]
    )

    aggregate_failures do
      expect(result["initial"]).to include(
        "subtotal" => 100,
        "tax" => 0,
        "total" => 100,
        "paymentAdjustmentTotal" => -200,
        "finalPaymentTotal" => -100
      )
      expect(result["restored"]).to eq(result["initial"])
    end
  end

  it "keeps known payment amounts but hides reconciliation and synchronization for an unknown total" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(ReceiptFormController.prototype)
      const amountTarget = () => ({ textContent: '¥0', title: '¥0', dataset: {} })
      const adjustment = amountTarget()
      const finalPayment = amountTarget()
      const paymentSum = amountTarget()
      const finalReconciliation = amountTarget()
      const difference = amountTarget()
      const visibilityTarget = () => {
        const target = { hidden: false }
        target.classList = { toggle: (_name, hidden) => { target.hidden = hidden } }
        return target
      }
      const warning = visibilityTarget()
      const syncButton = visibilityTarget()
      const paymentInput = { value: '123' }
      const paymentRow = { querySelector: () => paymentInput }
      Object.defineProperties(controller, {
        unsetLabelValue: { value: 'Unset' },
        paymentAdjustmentRowTargets: { value: [] },
        finalPaymentRowTargets: { value: [] },
        hasPaymentAdjustmentAmountTarget: { value: true },
        paymentAdjustmentAmountTarget: { value: adjustment },
        hasFinalPaymentAmountTarget: { value: true },
        finalPaymentAmountTarget: { value: finalPayment },
        hasPaymentAmountSumTarget: { value: true },
        paymentAmountSumTarget: { value: paymentSum },
        hasPaymentReconciliationFinalAmountTarget: { value: true },
        paymentReconciliationFinalAmountTarget: { value: finalReconciliation },
        hasPaymentDifferenceAmountTarget: { value: true },
        paymentDifferenceAmountTarget: { value: difference },
        paymentMismatchWarningTargets: { value: [warning] },
        syncPaymentAmountButtonTargets: { value: [syncButton] }
      })
      controller.shouldRenderAmountImmediately = () => true
      controller.syncPaymentSummaryLayout = () => {}
      controller.visiblePaymentRows = () => [paymentRow]
      controller.paymentAmountSum = () => 123
      let recalculations = 0
      controller.recalculate = () => { recalculations += 1 }
      controller.lastFinalPaymentTotal = null

      controller.syncPaymentAdjustmentSummary(-10, null)
      controller.syncPaymentReconciliationSummary(123, null)
      const unknownFinal = controller.currentFinalPaymentTotal()
      controller.syncPaymentAmountToFinal({ preventDefault () {} })
      const unknown = {
        adjustment: adjustment.textContent,
        finalPayment: finalPayment.textContent,
        paymentSum: paymentSum.textContent,
        finalReconciliation: finalReconciliation.textContent,
        difference: difference.textContent,
        warningHidden: warning.hidden,
        syncHidden: syncButton.hidden,
        currentFinal: unknownFinal,
        paymentInput: paymentInput.value,
        recalculations
      }
      controller.lastFinalPaymentTotal = 0
      controller.syncPaymentReconciliationSummary(123, 0)
      controller.syncPaymentAmountToFinal({ preventDefault () {} })

      process.stdout.write(JSON.stringify({
        unknown,
        zero: { warningHidden: warning.hidden, syncHidden: syncButton.hidden, paymentInput: paymentInput.value, recalculations }
      }))
    JAVASCRIPT

    expect(result).to eq(
      "unknown" => {
        "adjustment" => "-¥10", "finalPayment" => "Unset", "paymentSum" => "¥123",
        "finalReconciliation" => "Unset", "difference" => "Unset", "warningHidden" => true,
        "syncHidden" => true, "currentFinal" => nil, "paymentInput" => "123", "recalculations" => 0
      },
      "zero" => { "warningHidden" => false, "syncHidden" => false, "paymentInput" => 0, "recalculations" => 1 }
    )
  end

  it "does not write a negative amount through the payment synchronization action" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(ReceiptFormController.prototype)
      const input = { value: '100' }
      const row = { querySelector: () => input }
      controller.visiblePaymentRows = () => [row]
      controller.currentFinalPaymentTotal = () => -100
      controller.paymentAmountSum = () => 100
      controller.parseIntegerInput = (value) => Number(value)
      let recalculated = false
      controller.recalculate = () => { recalculated = true }

      controller.syncPaymentAmountToFinal({ preventDefault () {} })

      process.stdout.write(JSON.stringify({ value: input.value, recalculated }))
    JAVASCRIPT

    expect(result).to eq("value" => "100", "recalculated" => false)
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

  it "enforces Ruby whitespace and scale 3 for typed item quantity without rewriting the draft" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(ReceiptFormController.prototype)
      const quantity = { value: '1.234' }
      const inputs = {
        quantityInput: quantity,
        quantityUnitInput: { value: 'kilogram' },
        explicitLineTotalInput: { value: '250' },
        discountRateInput: { value: '' },
        taxRateInput: { value: '0' }
      }
      const row = {
        style: { display: '' },
        querySelector: (selector) => {
          const match = selector.match(/receipt-form-target="([^"]+)"/)
          return match ? inputs[match[1]] ?? null : null
        }
      }
      Object.defineProperties(controller, {
        itemRowTargets: { value: [row] },
        adjustmentRowTargets: { value: [] },
        paymentRowTargets: { value: [] },
        decimalQuantityUnitsValue: { value: 'gram,kilogram,milligram,liter,milliliter,cubic_centimeter' },
        receiptItemPriceMaxValue: { value: 999999999 },
        receiptItemLineTotalMaxValue: { value: 999999999 },
        receiptAdjustmentAmountMaxValue: { value: 999999999 },
        receiptPaymentAmountMaxValue: { value: 999999999 }
      })
      controller.pricingSourceModeForRow = () => 'explicit_line_total'

      const evaluate = (value) => {
        quantity.value = value
        const valid = controller.previewNumericInputsValid()
        return { valid, value: quantity.value }
      }
      const asciiQuantity = ' ' + String.fromCharCode(9) + '1.234' + String.fromCharCode(13, 10)
      const nbspQuantity = String.fromCharCode(160) + '1.234' + String.fromCharCode(160)
      process.stdout.write(JSON.stringify({
        scale3: evaluate('1.234'),
        trailingZeros: evaluate('1.2300'),
        scale4: evaluate('1.2345'),
        ascii: evaluate(asciiQuantity),
        ideographic: evaluate('　1.234　'),
        nbsp: evaluate(nbspQuantity),
        ambiguousComma: evaluate('1,000')
      }))
    JAVASCRIPT

    expect(result).to eq(
      "scale3" => { "valid" => true, "value" => "1.234" },
      "trailingZeros" => { "valid" => true, "value" => "1.2300" },
      "scale4" => { "valid" => false, "value" => "1.2345" },
      "ascii" => { "valid" => true, "value" => " \t1.234\r\n" },
      "ideographic" => { "valid" => false, "value" => "　1.234　" },
      "nbsp" => { "valid" => false, "value" => "\u00a01.234\u00a0" },
      "ambiguousComma" => { "valid" => true, "value" => "1,000" }
    )
  end

  it "suspends preview for tax and discount percentages that persistence would round" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(ReceiptFormController.prototype)
      const itemInputs = {
        quantityInput: { value: '1' },
        quantityUnitInput: { value: 'each' },
        priceInput: { value: '52' },
        discountRateInput: { value: '10.5' },
        taxRateInput: { value: '10.55' }
      }
      const adjustmentInputs = {
        adjustmentAmountInput: { value: '10' },
        adjustmentTaxRateInput: { value: '10.55' }
      }
      const buildRow = (inputs) => ({
        style: { display: '' },
        querySelector: (selector) => {
          const match = selector.match(/receipt-form-target="([^"]+)"/)
          return match ? inputs[match[1]] ?? null : null
        }
      })
      Object.defineProperties(controller, {
        itemRowTargets: { value: [buildRow(itemInputs)] },
        adjustmentRowTargets: { value: [buildRow(adjustmentInputs)] },
        paymentRowTargets: { value: [] },
        decimalQuantityUnitsValue: { value: 'gram,kilogram' },
        receiptItemPriceMaxValue: { value: 999999999 },
        receiptAdjustmentAmountMaxValue: { value: 999999999 },
        receiptPaymentAmountMaxValue: { value: 999999999 }
      })

      const boundaryValid = controller.previewNumericInputsValid()
      itemInputs.discountRateInput.value = '10.55'
      const discountTooPrecise = controller.previewNumericInputsValid()
      itemInputs.discountRateInput.value = '10.5'
      itemInputs.taxRateInput.value = '10.555'
      const itemTaxTooPrecise = controller.previewNumericInputsValid()
      itemInputs.taxRateInput.value = '10.55'
      adjustmentInputs.adjustmentTaxRateInput.value = '10.555'
      const adjustmentTaxTooPrecise = controller.previewNumericInputsValid()
      adjustmentInputs.adjustmentTaxRateInput.value = '10.55'
      itemInputs.discountRateInput.value = '10.5000000000000000000000001'
      const longDiscountTooPrecise = controller.previewNumericInputsValid()
      itemInputs.discountRateInput.value = '10.5'
      itemInputs.taxRateInput.value = '10.5500000000000000000000001'
      const longTaxTooPrecise = controller.previewNumericInputsValid()

      process.stdout.write(JSON.stringify({
        boundaryValid,
        discountTooPrecise,
        itemTaxTooPrecise,
        adjustmentTaxTooPrecise,
        longDiscountTooPrecise,
        longTaxTooPrecise,
        rawValues: {
          discount: itemInputs.discountRateInput.value,
          itemTax: itemInputs.taxRateInput.value,
          adjustmentTax: adjustmentInputs.adjustmentTaxRateInput.value
        }
      }))
    JAVASCRIPT

    expect(result).to eq(
      "boundaryValid" => true,
      "discountTooPrecise" => false,
      "itemTaxTooPrecise" => false,
      "adjustmentTaxTooPrecise" => false,
      "longDiscountTooPrecise" => false,
      "longTaxTooPrecise" => false,
      "rawValues" => {
        "discount" => "10.5",
        "itemTax" => "10.5500000000000000000000001",
        "adjustmentTax" => "10.55"
      }
    )
  end

  it "characterizes the current amount and quantity limit contract for all 14 units" do
    countable_unit_codes = %w[each item piece bag sheet unit box set]
    measurement_unit_codes = %w[gram kilogram milligram liter milliliter cubic_centimeter]
    boundary_quantities = %w[9999 9999.001 9999.999 10000]

    result = run_controller_script(<<~JAVASCRIPT)
      const countableUnitCodes = #{countable_unit_codes.to_json}
      const measurementUnitCodes = #{measurement_unit_codes.to_json}
      const boundaryQuantities = #{boundary_quantities.to_json}
      const allUnitCodes = [...countableUnitCodes, ...measurementUnitCodes]

      const buildInputs = ({ unitCode, quantity = '2', lineTotal = null }) => ({
        quantityInput: { value: String(quantity) },
        quantityUnitInput: { value: unitCode },
        priceInput: { value: '125' },
        discountRateInput: { value: '', dataset: { originalDiscountRate: '' } },
        taxRateInput: { value: '' },
        lineTotalInput: {
          value: lineTotal === null ? '' : String(lineTotal),
          dataset: {
            originalLineTotal: lineTotal === null ? '' : String(lineTotal),
            originalSavedLineTotal: lineTotal === null ? '' : String(lineTotal)
          }
        },
        originalLineTotalInput: { value: lineTotal === null ? '' : String(lineTotal) }
      })

      const buildRow = (inputs) => ({
        style: { display: '' },
        querySelector (selector) {
          const match = selector.match(/receipt-form-target="([^"]+)"/)
          return match ? inputs[match[1]] ?? null : null
        },
        querySelectorAll () { return [] }
      })

      const buildController = (row = null) => {
        const controller = Object.create(ReceiptFormController.prototype)
        Object.defineProperties(controller, {
          itemRowTargets: { value: row ? [row] : [] },
          adjustmentRowTargets: { value: [] },
          paymentRowTargets: { value: [] },
          countableQuantityUnitsValue: { value: countableUnitCodes.join(',') },
          decimalQuantityUnitsValue: { value: measurementUnitCodes.join(',') },
          receiptTaxBasisValue: { value: 'internal' },
          receiptItemPriceMaxValue: { value: 999999999 },
          receiptItemLineTotalMaxValue: { value: 999999999 },
          receiptAdjustmentAmountMaxValue: { value: 999999999 },
          receiptPaymentAmountMaxValue: { value: 999999999 },
          receiptTotalAmountMaxValue: { value: 999999999 },
          receiptTaxAmountMaxValue: { value: 999999999 },
          hasTotalAmountTarget: { value: false },
          hasSubtotalAmountTarget: { value: false },
          hasTaxAmountTarget: { value: false },
          hasTaxRateSummaryTarget: { value: false }
        })
        return controller
      }

      const calculatedAmount = (unitCode, lineTotal) => {
        const controller = buildController()
        const inputs = buildInputs({ unitCode, lineTotal })
        const originalLineTotal = controller.originalLineTotalFor({
          quantity: 2,
          price: 125,
          priceInputPresent: true,
          quantityUnit: unitCode,
          lineTotalInput: inputs.lineTotalInput
        })
        const calculatedLineTotal = controller.lineTotalFor({
          originalLineTotal,
          discountRatePercent: null,
          discountRateInput: inputs.discountRateInput,
          lineTotalInput: inputs.lineTotalInput
        })
        return controller.clampNumber(calculatedLineTotal, 0, controller.receiptItemLineTotalMaxValue)
      }

      const acceptedByPreviewValidation = (unitCode, quantity) => {
        const inputs = buildInputs({ unitCode, quantity })
        const controller = buildController(buildRow(inputs))
        return controller.previewNumericInputsValid()
      }

      const recalculationState = (unitCode, quantity) => {
        const inputs = buildInputs({ unitCode, quantity })
        const controller = buildController(buildRow(inputs))
        let internalQuantity = null
        let previewUnavailable = false

        controller.renderUnavailablePreview = () => { previewUnavailable = true }
        controller.animateLineTotal = () => {}
        controller.itemAmountSourcePresentFor = () => true
        controller.originalLineTotalFor = ({ quantity: value }) => {
          internalQuantity = value
          return 0
        }
        controller.lineTotalFor = () => 0
        controller.syncLineTotalState = () => {}
        controller.inheritedAdjustmentTaxRate = () => null
        controller.purchaseInputsChangedForPreview = () => false
        controller.internalTaxTotal = () => 0
        controller.preserveInitialReceiptAmountsForPreview = () => false
        controller.syncPaymentAdjustmentSummary = () => {}
        controller.syncPaymentReconciliationSummary = () => {}
        controller.paymentAmountSum = () => 0

        controller.recalculate()
        return { internalQuantity, previewUnavailable }
      }

      const result = Object.fromEntries(allUnitCodes.map((unitCode) => [
        unitCode,
        {
          amounts: {
            explicit: calculatedAmount(unitCode, 777),
            missing: calculatedAmount(unitCode, null)
          },
          boundaries: Object.fromEntries(boundaryQuantities.map((quantity) => [
            quantity,
            {
              accepted: acceptedByPreviewValidation(unitCode, quantity),
              recalculation: recalculationState(unitCode, quantity)
            }
          ]))
        }
      ]))

      process.stdout.write(JSON.stringify(result))
    JAVASCRIPT

    expected = (countable_unit_codes + measurement_unit_codes).to_h do |code|
      measurement = measurement_unit_codes.include?(code)
      boundaries = boundary_quantities.to_h do |quantity|
        accepted = quantity != '10000' && (measurement || quantity == '9999')
        recalculation =
          if accepted
            { "internalQuantity" => 9999, "previewUnavailable" => false }
          else
            { "internalQuantity" => nil, "previewUnavailable" => true }
          end
        [ quantity, { "accepted" => accepted, "recalculation" => recalculation } ]
      end

      [
        code,
        {
          "amounts" => {
            "explicit" => measurement ? 777 : 250,
            "missing" => measurement ? 0 : 250
          },
          "boundaries" => boundaries
        }
      ]
    end

    expect(result).to eq(expected)
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
