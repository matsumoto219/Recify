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
    changed_price_before_discount: nil,
    changed_quantity_unit: nil
  )
    run_controller_script(<<~JAVASCRIPT)
      const itemDefinitions = #{items.to_json}
      const adjustmentDefinitions = #{adjustments.to_json}
      const amountTarget = () => ({ value: null, textContent: '', title: '', dataset: {} })
      const rows = itemDefinitions.map((definition) => {
        const inputs = {
          quantityInput: { value: String(definition.quantity ?? 1) },
          quantityUnitInput: { value: 'each' },
          priceInput: { value: definition.price === null ? '' : String(definition.price) },
          discountRateInput: {
            value: String(definition.discountRate ?? ''),
            dataset: { originalDiscountRate: String(definition.discountRate ?? '') }
          },
          taxRateInput: { value: String(definition.taxRate) },
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
        multipleTaxRatesLabelValue: { value: 'Multiple tax rates' },
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
        hasTaxRateSummaryTarget: { value: #{(!initial_tax_rate_summary.nil?).to_json} },
        taxRateSummaryTarget: { value: taxRateSummary }
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
          firstLineTotal: Number(rows[0].inputs.lineTotalInput.value)
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

        return amounts
      }

      controller.recalculate()
      const initial = snapshot()
      const changedDiscountRate = #{changed_discount_rate.to_json}
      const changedPrice = #{changed_price.to_json}
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
      "firstLineTotal" => 0,
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
        taxRateSummaryTarget: { value: taxRateSummary }
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
