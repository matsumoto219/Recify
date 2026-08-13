import { Controller } from '@hotwired/stimulus'
import {
  normalizedOptionalDecimalInput,
  normalizeNumericInputText,
  parseDecimalInput,
  parseDiscountRateInput,
  parseIntegerInput,
  previewValueInRange,
  quantityUnitList
} from 'receipts/numeric_input'
import {
  clampNumber,
  discountedLineTotal,
  easeOutCubic,
  externalTaxTotal,
  formatNumber,
  formatPaymentDifference,
  formatSignedAmount,
  formatTaxRateSummary,
  internalTaxTotal,
  normalizeRoundingMode,
  referenceItemExtension,
  roundLineAmount
} from 'receipts/amount_preview'
import {
  REVIEW_REASON_TARGET_LINK_SELECTOR,
  reviewTargetHash,
  reviewTargetIdFromHash,
  reviewTargetUrl,
  samePageReviewTargetUrl
} from 'receipts/review_targets'

const DEFAULT_AMOUNT_MAX = 999999999
const LINE_TOTAL_TOOLTIP_DELAY_MS = 500
const CONTINUOUS_AMOUNT_UPDATE_THRESHOLD_MS = 150
const REVIEW_TARGET_CLICK_SCROLL_DELAY_MS = 1000

export default class extends Controller {
  static targets = [
    'template',
    'adjustmentTemplate',
    'paymentTemplate',
    'itemRow',
    'destroyField',
    'adjustmentRow',
    'adjustmentDestroyField',
    'paymentRow',
    'paymentDestroyField',
    'paymentAmountInput',
    'initialPurchaseInputFingerprint',
    'adjustmentKindInput',
    'adjustmentSignInput',
    'adjustmentSignLabel',
    'adjustmentSignLabelWrapper',
    'adjustmentSignSelect',
    'adjustmentSignSelectWrapper',
    'adjustmentAmountInput',
    'adjustmentTaxRateInput',
    'adjustmentDetailsPanel',
    'adjustmentDetailsToggle',
    'adjustmentDetailsIcon',
    'adjustmentAbsenceConfirmation',
    'adjustmentAbsenceConfirmationField',
    'quantityInput',
    'quantityUnitInput',
    'priceInput',
    'pricingSourceModeInput',
    'pricingModePanel',
    'pricingSourceSummary',
    'referencePriceAmountInput',
    'referenceQuantityInput',
    'referenceQuantityUnitInput',
    'referencePriceTaxInclusionInput',
    'explicitLineTotalInput',
    'explicitLineTotalHelp',
    'clearItemDiscountBeforeExplicitInput',
    'invalidItemSourceSummary',
    'discountRateInput',
    'taxRateInput',
    'lineTotalDisplay',
    'lineTotalTooltip',
    'lineTotalInput',
    'originalLineTotalInput',
    'itemDetailsPanel',
    'itemDetailsToggle',
    'itemDetailsIcon',
    'totalAmount',
    'subtotalAmount',
    'taxAmount',
    'taxRateSummary',
    'paymentAdjustmentRow',
    'paymentAdjustmentAmount',
    'finalPaymentRow',
    'finalPaymentAmount',
    'paymentAmountSum',
    'paymentReconciliationFinalAmount',
    'paymentDifferenceAmount',
    'paymentSummaryGrid',
    'paymentMismatchWarning',
    'syncPaymentAmountButton'
  ]

  static values = {
    nextIndex: Number,
    nextAdjustmentIndex: Number,
    nextPaymentIndex: Number,
    roundingMode: { type: String, default: 'floor' },
    discountRoundingMode: { type: String, default: 'round' },
    deleteConfirmationEnabled: { type: Boolean, default: true },
    deleteConfirmationMessage: { type: String, default: 'Delete this item?' },
    deleteAdjustmentConfirmationMessage: { type: String, default: 'Delete this adjustment?' },
    deletePaymentConfirmationMessage: { type: String, default: 'Delete this payment?' },
    deleteConfirmTitle: { type: String, default: 'Delete?' },
    deleteConfirmLabel: { type: String, default: 'Delete' },
    deleteConfirmBackdrop: { type: String, default: 'plain' },
    pricingSourceDiscountClearConfirmationMessage: { type: String, default: 'Clear the item discount and switch the pricing method?' },
    pricingSourceDiscountClearConfirmTitle: { type: String, default: 'Change pricing method?' },
    pricingSourceDiscountClearConfirmLabel: { type: String, default: 'Clear discount and change' },
    receiptTaxBasis: { type: String, default: 'internal' },
    subtotalLabel: { type: String, default: 'Subtotal' },
    unsetLabel: { type: String, default: 'Unset' },
    multipleTaxRatesLabel: { type: String, default: 'Multiple tax rates' },
    adjustmentPaymentKinds: { type: String, default: 'point_usage' },
    adjustmentPurchaseKinds: { type: String, default: 'service_charge,late_night_charge,delivery_fee,bag_fee,handling_fee,coupon,return_refund' },
    adjustmentPaymentLabelPattern: { type: String, default: '' },
    adjustmentTaxDetailRates: Array,
    adjustmentTaxDetailEvidenceStale: { type: Boolean, default: false },
    purchaseInputsChanged: { type: Boolean, default: false },
    adjustmentSurchargeKinds: { type: String, default: 'service_charge,late_night_charge,delivery_fee,bag_fee,handling_fee' },
    adjustmentDiscountKinds: { type: String, default: 'receipt_discount,coupon,point_usage,return_refund' },
    adjustmentSurchargeLabel: { type: String, default: 'Surcharge' },
    adjustmentDiscountLabel: { type: String, default: 'Discount' },
    countableQuantityUnits: { type: String, default: 'each,item,piece,bag,sheet,unit,box,set' },
    decimalQuantityUnits: { type: String, default: 'gram,kilogram,milligram,liter,milliliter,cubic_centimeter' },
    defaultQuantityUnit: { type: String, default: 'each' },
    integerQuantityStep: { type: String, default: '1' },
    decimalQuantityStep: { type: String, default: '0.001' },
    referencePricingContract: Object,
    referenceProjectionFallbackTaxRate: { type: String, default: '' },
    receiptTotalAmountMax: { type: Number, default: DEFAULT_AMOUNT_MAX },
    receiptItemPriceMax: { type: Number, default: DEFAULT_AMOUNT_MAX },
    receiptItemLineTotalMax: { type: Number, default: DEFAULT_AMOUNT_MAX },
    receiptTaxAmountMax: { type: Number, default: DEFAULT_AMOUNT_MAX },
    receiptAdjustmentAmountMax: { type: Number, default: DEFAULT_AMOUNT_MAX },
    receiptPaymentAmountMax: { type: Number, default: DEFAULT_AMOUNT_MAX },
    reviewItemTargetPrefix: String,
    reviewItemsTarget: String,
    reviewAdjustmentTargetPrefix: String,
    reviewAdjustmentsTarget: String
  }

  connect () {
    this.lineTotalTooltipDelay = LINE_TOTAL_TOOLTIP_DELAY_MS
    this.continuousAmountUpdateThreshold = CONTINUOUS_AMOUNT_UPDATE_THRESHOLD_MS
    this.handleBeforeCache = this.handleBeforeCache.bind(this)
    this.handleReviewTargetClick = this.handleReviewTargetClick.bind(this)
    this.handleHashChange = this.handleHashChange.bind(this)
    this.handleInvalidItemField = this.handleInvalidItemField.bind(this)
    document.addEventListener('turbo:before-cache', this.handleBeforeCache)
    this.element.addEventListener('click', this.handleReviewTargetClick)
    this.element.addEventListener('invalid', this.handleInvalidItemField, true)
    window.addEventListener('hashchange', this.handleHashChange)
    this.syncPricingSourceModes()
    this.syncItemDetailsPanels()
    this.syncAdjustmentDetailsPanels()
    this.syncQuantityInputSteps()
    this.syncAdjustmentSigns()
    this.syncAdjustmentAbsenceConfirmation()
    this.captureInitialReceiptAmounts()
    this.captureInitialPurchaseInputFingerprint()
    this.syncInitialPricingPreviews()
    this.syncPaymentSummaryLayout()
    this.expandItemDetailsFromHash()
    this.expandAdjustmentDetailsFromHash()
    this.revealInvalidItemSourceRows()
  }

  disconnect () {
    document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
    this.element.removeEventListener('click', this.handleReviewTargetClick)
    this.element.removeEventListener('invalid', this.handleInvalidItemField, true)
    window.removeEventListener('hashchange', this.handleHashChange)
    this.clearReviewTargetScrollTimer()
    this.itemRowTargets.forEach((row) => this.clearLineTotalTooltipTimer(row))
    this.amountAnimationTargets().forEach((target) => this.cancelAmountAnimation(target))
  }

  addItem (event) {
    event.preventDefault()

    const template = this.templateTarget.innerHTML.trim()
    if (!template) return

    const index = this.nextIndexValue
    const html = template.replace(/NEW_RECORD/g, String(index))

    event.currentTarget.insertAdjacentHTML('beforebegin', html)
    this.nextIndexValue = index + 1
    this.syncPricingSourceModes()
    this.syncItemDetailsPanels()
    this.syncQuantityInputSteps()
  }

  addAdjustment (event) {
    event.preventDefault()

    const template = this.adjustmentTemplateTarget.innerHTML.trim()
    if (!template) return

    const index = this.nextAdjustmentIndexValue
    const html = template.replace(/NEW_ADJUSTMENT_RECORD/g, String(index))

    event.currentTarget.insertAdjacentHTML('beforebegin', html)
    this.nextAdjustmentIndexValue = index + 1
    this.syncAdjustmentDetailsPanels()
    this.syncAdjustmentSigns()
    this.syncAdjustmentAbsenceConfirmation()
    this.recalculate()
  }

  addPayment (event) {
    event.preventDefault()

    const template = this.paymentTemplateTarget.innerHTML.trim()
    if (!template) return

    const index = this.nextPaymentIndexValue
    const html = template.replace(/NEW_PAYMENT_RECORD/g, String(index))

    event.currentTarget.insertAdjacentHTML('beforebegin', html)
    this.nextPaymentIndexValue = index + 1
    this.recalculate()
  }

  async removeAdjustment (event) {
    event.preventDefault()

    const row = this.adjustmentRowForAction(event.currentTarget)
    if (!row) return

    const skipConfirmation = event.currentTarget.dataset.receiptFormSkipDeleteConfirmation === 'true'
    delete event.currentTarget.dataset.receiptFormSkipDeleteConfirmation

    if (!skipConfirmation && !(await this.confirmDelete(this.deleteAdjustmentConfirmationMessageValue, event.currentTarget))) return

    const destroyField = row.querySelector('[data-receipt-form-target="adjustmentDestroyField"]')
    const rowContainer = this.adjustmentRowContainer(row)

    if (destroyField) {
      destroyField.value = '1'
      row.style.display = 'none'
      if (rowContainer !== row) rowContainer.style.display = 'none'
    } else {
      row.style.display = 'none'
      rowContainer.remove()
    }

    this.syncAdjustmentAbsenceConfirmation()
    this.recalculate()
  }

  async removePayment (event) {
    event.preventDefault()

    const row = this.paymentRowForAction(event.currentTarget)
    if (!row) return

    const skipConfirmation = event.currentTarget.dataset.receiptFormSkipDeleteConfirmation === 'true'
    delete event.currentTarget.dataset.receiptFormSkipDeleteConfirmation

    if (!skipConfirmation && !(await this.confirmDelete(this.deletePaymentConfirmationMessageValue, event.currentTarget))) return

    const destroyField = row.querySelector('[data-receipt-form-target="paymentDestroyField"]')
    const rowContainer = this.paymentRowContainer(row)

    if (destroyField) {
      destroyField.value = '1'
      row.style.display = 'none'
      if (rowContainer !== row) rowContainer.style.display = 'none'
    } else {
      row.style.display = 'none'
      rowContainer.remove()
    }

    this.recalculate()
  }

  adjustmentRowForAction (element) {
    const directRow = element.closest('[data-receipt-form-target="adjustmentRow"]')
    if (directRow) return directRow

    return element.closest('[data-controller~="swipe-action"]')?.querySelector('[data-receipt-form-target="adjustmentRow"]')
  }

  adjustmentRowContainer (row) {
    return row.closest('[data-controller~="swipe-action"]') || row
  }

  paymentRowForAction (element) {
    const directRow = element.closest('[data-receipt-form-target="paymentRow"]')
    if (directRow) return directRow

    return element.closest('[data-controller~="swipe-action"]')?.querySelector('[data-receipt-form-target="paymentRow"]')
  }

  paymentRowContainer (row) {
    return row.closest('[data-controller~="swipe-action"]') || row
  }

  adjustmentKindChanged (event) {
    const row = event.currentTarget.closest('[data-receipt-form-target="adjustmentRow"]')
    this.syncAdjustmentEffectForRow(row)
    this.syncAdjustmentSignForRow(row)
    this.recalculate()
  }

  adjustmentLabelChanged (event) {
    const row = event.currentTarget.closest('[data-receipt-form-target="adjustmentRow"]')
    this.syncAdjustmentEffectForRow(row)
    this.recalculate()
  }

  toggleAdjustmentDetails (event) {
    event.preventDefault()

    const toggle = event.currentTarget
    const row = toggle.closest('[data-receipt-form-target="adjustmentRow"]')
    if (!row) return

    const panel = row.querySelector('[data-receipt-form-target="adjustmentDetailsPanel"]')
    const toggles = row.querySelectorAll('[data-receipt-form-target="adjustmentDetailsToggle"]')
    const icons = row.querySelectorAll('[data-receipt-form-target="adjustmentDetailsIcon"]')
    if (!panel) return

    const willOpen = !this.adjustmentDetailsPanelOpen(panel)
    this.setAdjustmentDetailsOpen({ row, panel, toggles, icons, open: willOpen })
  }

  quantityUnitChanged (event) {
    const unitSelect = event.currentTarget

    this.syncQuantityInputStepForUnitSelect(unitSelect, 'quantityInput')
    this.recalculate()
  }

  referenceQuantityUnitChanged (event) {
    const unitSelect = event.currentTarget

    this.syncQuantityInputStepForUnitSelect(unitSelect, 'referenceQuantityInput')
    this.recalculate()
  }

  async pricingSourceModeChanged (event) {
    const input = event.currentTarget
    const row = input.closest('[data-receipt-form-target="itemRow"]')
    if (!row) return

    const previousMode = this.activePricingSourceModeForRow(row)
    const nextMode = this.pricingSourceModeFromValue(input.value)
    if (this.formulaPricingSourceMode(previousMode) && nextMode === 'explicit_line_total' &&
      this.itemDiscountClearConfirmationRequired(row)) {
      const confirmed = await this.confirmPricingSourceDiscountClear(input)
      if (!confirmed) {
        input.value = previousMode === 'unclassified' ? '' : previousMode
        this.syncPricingSourceModeForRow(row, previousMode)
        return
      }

      const clearDiscountInput = row.querySelector(
        '[data-receipt-form-target="clearItemDiscountBeforeExplicitInput"]'
      )
      const discountRateInput = row.querySelector('[data-receipt-form-target="discountRateInput"]')
      if (discountRateInput) {
        row.dataset.receiptFormFormulaDiscountDraft = discountRateInput.value
        discountRateInput.value = ''
      }
      if (clearDiscountInput) clearDiscountInput.value = '1'
    } else if (nextMode !== 'explicit_line_total') {
      const clearDiscountInput = row.querySelector(
        '[data-receipt-form-target="clearItemDiscountBeforeExplicitInput"]'
      )
      const discountRateInput = row.querySelector('[data-receipt-form-target="discountRateInput"]')
      if (clearDiscountInput?.value === '1' && discountRateInput) {
        if (Object.prototype.hasOwnProperty.call(row.dataset, 'receiptFormFormulaDiscountDraft')) {
          discountRateInput.value = row.dataset.receiptFormFormulaDiscountDraft
        } else if (Object.prototype.hasOwnProperty.call(row.dataset, 'receiptFormPersistedFormulaDiscountInput')) {
          discountRateInput.value = row.dataset.receiptFormPersistedFormulaDiscountInput
        }
        delete row.dataset.receiptFormFormulaDiscountDraft
      }
      if (clearDiscountInput) clearDiscountInput.value = '0'
    }

    this.syncPricingSourceModeForRow(row, nextMode)
    this.recalculate({ pricingSourceChangedRow: previousMode === nextMode ? null : row })
  }

  explicitLineTotalChanged () {
    this.recalculate()
  }

  discountRateChanged (event) {
    const row = event.currentTarget.closest('[data-receipt-form-target="itemRow"]')
    if (row) this.syncPricingSourceSummaryForRow(row)
    this.recalculate()
  }

  confirmPricingSourceDiscountClear (restoreFocusElement) {
    const confirm = window.RecifyConfirm?.confirm
    if (typeof confirm !== 'function') return Promise.resolve(false)

    return confirm(this.pricingSourceDiscountClearConfirmationMessageValue, {
      icon: 'sync_alt',
      title: this.pricingSourceDiscountClearConfirmTitleValue,
      confirmLabel: this.pricingSourceDiscountClearConfirmLabelValue,
      backdrop: this.deleteConfirmBackdropValue,
      restoreFocusElement
    })
  }

  syncPricingSourceModes () {
    Array.from(this.itemRowTargets || []).forEach((row) => {
      this.syncPricingSourceModeForRow(row, this.pricingSourceModeForRow(row))
    })
  }

  syncPricingSourceModeForRow (row, mode) {
    const normalizedMode = this.pricingSourceModeFromValue(mode)
    row.dataset.receiptFormActivePricingMode = normalizedMode

    row.querySelectorAll('[data-receipt-form-target~="pricingModePanel"]').forEach((panel) => {
      const active = this.pricingElementSupportsMode(panel, normalizedMode)
      panel.hidden = !active
      panel.toggleAttribute('inert', !active)
      panel.setAttribute('aria-hidden', String(!active))
      panel.querySelectorAll('input, select, textarea').forEach((input) => {
        input.disabled = !active
        if (input.dataset?.receiptFormRequiredWhenActive === 'true') input.required = active
      })
    })

    row.querySelectorAll('[data-receipt-form-target~="pricingSourceSummary"]').forEach((summary) => {
      summary.hidden = !this.pricingElementSupportsMode(summary, normalizedMode)
    })
    this.syncPricingSourceSummaryForRow(row, normalizedMode)
  }

  syncPricingSourceSummaryForRow (row, mode = this.pricingSourceModeForRow(row)) {
    this.syncExplicitLineTotalSemantics(row)
    const summary = Array.from(
      row.querySelectorAll('[data-receipt-form-target~="pricingSourceSummary"]')
    ).find((candidate) => this.pricingElementSupportsMode(candidate, mode))
    if (!summary || mode === 'unclassified') return

    const values = this.pricingSourceSummaryValues(row, mode)
    const complete = Object.values(values).every((value) => String(value ?? '').trim() !== '')
    const explicitTemplate = mode === 'explicit_line_total'
      ? (this.itemDiscountSourcePresent(row)
          ? summary.dataset.receiptFormSummaryTemplateWithDiscount
          : summary.dataset.receiptFormSummaryTemplateWithoutDiscount)
      : null
    const explicitUnset = mode === 'explicit_line_total'
      ? (this.itemDiscountSourcePresent(row)
          ? summary.dataset.receiptFormSummaryUnsetWithDiscount
          : summary.dataset.receiptFormSummaryUnsetWithoutDiscount)
      : null
    const template = complete
      ? (explicitTemplate || summary.dataset.receiptFormSummaryTemplate)
      : (explicitUnset || summary.dataset.receiptFormSummaryUnset)
    if (typeof template !== 'string' || template === '') return

    summary.textContent = template.replace(/%\{([a-z_]+)\}/g, (placeholder, key) => (
      Object.prototype.hasOwnProperty.call(values, key) ? values[key] : placeholder
    ))
  }

  pricingSourceSummaryValues (row, mode) {
    const inputValue = (target) => String(
      row.querySelector(`[data-receipt-form-target="${target}"]`)?.value ?? ''
    ).trim()
    const optionLabel = (target) => {
      const select = row.querySelector(`[data-receipt-form-target="${target}"]`)
      return String(select?.selectedOptions?.[0]?.textContent ?? select?.value ?? '').trim()
    }

    if (mode === 'count_unit_price') {
      return {
        price: inputValue('priceInput'),
        quantity: inputValue('quantityInput'),
        unit: optionLabel('quantityUnitInput')
      }
    }
    if (mode === 'reference_quantity_price') {
      return {
        amount: inputValue('referencePriceAmountInput'),
        quantity: inputValue('referenceQuantityInput'),
        unit: optionLabel('referenceQuantityUnitInput'),
        tax_inclusion: row.querySelector(
          '[data-receipt-form-target="referencePriceTaxInclusionInput"]'
        )?.dataset.receiptFormTaxInclusionLabel || ''
      }
    }

    return { amount: inputValue('explicitLineTotalInput') }
  }

  syncExplicitLineTotalSemantics (row) {
    const input = row.querySelector('[data-receipt-form-target="explicitLineTotalInput"]')
    const help = row.querySelector('[data-receipt-form-target="explicitLineTotalHelp"]')
    const discountSourcePresent = this.itemDiscountSourcePresent(row)

    const label = discountSourcePresent
      ? input?.dataset?.receiptFormLabelWithDiscount
      : input?.dataset?.receiptFormLabelWithoutDiscount
    if (typeof label === 'string' && label !== '') input?.setAttribute('aria-label', label)

    const control = input?.closest?.('.receipt-form-explicit-line-total-control')
    const decrementButton = control?.querySelector('[data-number-field-stepper-direction="decrement"]')
    const incrementButton = control?.querySelector('[data-number-field-stepper-direction="increment"]')
    const decrementLabel = discountSourcePresent
      ? input?.dataset?.receiptFormDecrementLabelWithDiscount
      : input?.dataset?.receiptFormDecrementLabelWithoutDiscount
    const incrementLabel = discountSourcePresent
      ? input?.dataset?.receiptFormIncrementLabelWithDiscount
      : input?.dataset?.receiptFormIncrementLabelWithoutDiscount
    if (typeof decrementLabel === 'string' && decrementLabel !== '') {
      decrementButton?.setAttribute('aria-label', decrementLabel)
    }
    if (typeof incrementLabel === 'string' && incrementLabel !== '') {
      incrementButton?.setAttribute('aria-label', incrementLabel)
    }

    const helpText = discountSourcePresent
      ? help?.dataset?.receiptFormTextWithDiscount
      : help?.dataset?.receiptFormTextWithoutDiscount
    if (typeof helpText === 'string' && helpText !== '') help.textContent = helpText
  }

  pricingElementSupportsMode (element, mode) {
    return String(element.dataset.receiptFormPricingModes ?? '')
      .split(/\s+/)
      .filter((value) => value !== '')
      .includes(mode)
  }

  pricingSourceModeForRow (row) {
    const input = row.querySelector('[data-receipt-form-target="pricingSourceModeInput"]')
    return this.pricingSourceModeFromValue(input?.value)
  }

  activePricingSourceModeForRow (row) {
    return this.pricingSourceModeFromValue(
      row.dataset.receiptFormActivePricingMode ?? this.pricingSourceModeForRow(row)
    )
  }

  pricingSourceModeFromValue (value) {
    const mode = String(value ?? '').trim()
    if (['count_unit_price', 'reference_quantity_price', 'explicit_line_total'].includes(mode)) return mode

    return 'unclassified'
  }

  formulaPricingSourceMode (mode) {
    return mode === 'count_unit_price' || mode === 'reference_quantity_price'
  }

  itemDiscountSourcePresent (row) {
    const discountRateInput = row.querySelector('[data-receipt-form-target="discountRateInput"]')
    if (String(discountRateInput?.value ?? '').trim() !== '') return true

    const clearDiscountInput = row.querySelector(
      '[data-receipt-form-target="clearItemDiscountBeforeExplicitInput"]'
    )
    if (clearDiscountInput?.value === '1') return false

    return row.dataset?.receiptFormHasPersistedAbsoluteDiscountSource === 'true' ||
      row.dataset?.receiptFormHasPersistedExplicitPositiveDiscountRateSource === 'true'
  }

  itemDiscountClearConfirmationRequired (row) {
    const clearDiscountInput = row.querySelector(
      '[data-receipt-form-target="clearItemDiscountBeforeExplicitInput"]'
    )
    if (clearDiscountInput?.value === '1') return false
    if (this.itemDiscountSourcePresent(row)) return true

    return Object.prototype.hasOwnProperty.call(row.dataset ?? {}, 'receiptFormPersistedFormulaDiscountInput')
  }

  async removeItem (event) {
    event.preventDefault()

    const row = this.itemRowForAction(event.currentTarget)
    if (!row) return

    const skipConfirmation = event.currentTarget.dataset.receiptFormSkipDeleteConfirmation === 'true'
    delete event.currentTarget.dataset.receiptFormSkipDeleteConfirmation

    if (!skipConfirmation && !(await this.confirmDelete(this.deleteConfirmationMessageValue, event.currentTarget))) return

    const destroyField = row.querySelector('[data-receipt-form-target="destroyField"]')
    const rowContainer = this.itemRowContainer(row)

    if (destroyField) {
      // 既存レコード → _destroy を有効にして非表示
      destroyField.value = '1'
      row.style.display = 'none'
      if (rowContainer !== row) rowContainer.style.display = 'none'
    } else {
      // 新規レコード → DOMから削除
      row.style.display = 'none'
      rowContainer.remove()
    }

    this.recalculate()
  }

  itemRowForAction (element) {
    const directRow = element.closest('[data-receipt-form-target="itemRow"]')
    if (directRow) return directRow

    return element.closest('[data-controller~="swipe-action"]')?.querySelector('[data-receipt-form-target="itemRow"]')
  }

  itemRowContainer (row) {
    return row.closest('[data-controller~="swipe-action"]') || row
  }

  confirmDelete (message, restoreFocusElement) {
    if (!this.deleteConfirmationEnabledValue) return Promise.resolve(true)

    const confirm = window.RecifyConfirm?.confirm
    if (typeof confirm !== 'function') return Promise.resolve(false)

    return confirm(message, {
      variant: 'danger',
      icon: 'delete',
      title: this.deleteConfirmTitleValue,
      confirmLabel: this.deleteConfirmLabelValue,
      backdrop: this.deleteConfirmBackdropValue,
      restoreFocusElement
    })
  }

  handleReviewTargetClick (event) {
    const link = event.target?.closest?.(REVIEW_REASON_TARGET_LINK_SELECTOR)
    if (!link || !this.element.contains(link)) return

    const url = this.reviewTargetUrl(link.getAttribute('href'))
    if (!url || !this.samePageReviewTargetUrl(url)) return

    const targetId = this.reviewTargetIdFromHash(url.hash)
    if (targetId === this.reviewItemsTargetValue || targetId === this.reviewAdjustmentsTargetValue) {
      event.preventDefault()
      this.navigateReviewTargetHash(targetId)
      this.scheduleReviewTargetScroll(document.getElementById(targetId), {
        block: 'start',
        delay: event.detail === 1 ? REVIEW_TARGET_CLICK_SCROLL_DELAY_MS : 0
      })
      return
    }

    if (this.reviewItemTargetId(targetId)) {
      event.preventDefault()

      if (this.expandItemDetailsForReviewTarget(targetId, { scroll: true })) {
        this.pushReviewTargetHash(targetId)
        return
      }

      const fallbackTargetId = link.dataset.reviewReasonTarget || this.reviewItemsTargetValue
      this.pushReviewTargetHash(fallbackTargetId)
      this.scrollReviewTargetFallback(fallbackTargetId)
      return
    }

    if (!this.reviewAdjustmentTargetId(targetId)) return

    event.preventDefault()
    const scrollDelay = event.detail === 1 ? REVIEW_TARGET_CLICK_SCROLL_DELAY_MS : 0

    if (this.expandAdjustmentDetailsForReviewTarget(targetId, { scroll: false, focus: true })) {
      this.navigateReviewTargetHash(targetId)
      this.scheduleReviewTargetScroll(document.getElementById(targetId), { delay: scrollDelay })
      return
    }

    this.navigateReviewTargetHash(this.reviewAdjustmentsTargetValue)
    this.scheduleReviewTargetScroll(
      document.getElementById(this.reviewAdjustmentsTargetValue),
      { block: 'start', delay: scrollDelay }
    )
  }

  handleHashChange () {
    this.clearReviewTargetScrollTimer()
    this.expandItemDetailsFromHash({ scroll: true })
    this.expandAdjustmentDetailsFromHash({ scroll: true })
  }

  reviewTargetUrl (href) {
    return reviewTargetUrl(href, window.location.href)
  }

  samePageReviewTargetUrl (url) {
    return samePageReviewTargetUrl(url, window.location)
  }

  currentReviewTargetId () {
    return this.reviewTargetIdFromHash(window.location.hash)
  }

  reviewTargetIdFromHash (hash) {
    return reviewTargetIdFromHash(hash)
  }

  reviewItemTargetId (targetId) {
    return this.reviewItemTargetPrefixValue !== '' &&
      typeof targetId === 'string' &&
      targetId.startsWith(this.reviewItemTargetPrefixValue)
  }

  reviewAdjustmentTargetId (targetId) {
    return this.reviewAdjustmentTargetPrefixValue !== '' &&
      typeof targetId === 'string' &&
      targetId.startsWith(this.reviewAdjustmentTargetPrefixValue)
  }

  expandItemDetailsFromHash ({ scroll = true } = {}) {
    const targetId = this.currentReviewTargetId()
    if (!this.reviewItemTargetId(targetId)) return false

    return this.expandItemDetailsForReviewTarget(targetId, { scroll })
  }

  expandItemDetailsForReviewTarget (targetId, { scroll = true } = {}) {
    const row = this.reviewItemRowForTarget(targetId)
    if (!this.reviewItemRowVisible(row)) {
      if (scroll) this.scrollReviewTargetFallback()
      return false
    }

    const panel = row.querySelector('[data-receipt-form-target="itemDetailsPanel"]')
    const toggles = row.querySelectorAll('[data-receipt-form-target="itemDetailsToggle"]')
    const icons = row.querySelectorAll('[data-receipt-form-target="itemDetailsIcon"]')
    if (!panel) return false

    this.hideLineTotalTooltipFor(row)
    this.setItemDetailsOpen({ row, panel, toggles, icons, open: true })
    if (scroll) this.scrollReviewTargetIntoView(row)

    return true
  }

  reviewItemRowForTarget (targetId) {
    const row = document.getElementById(targetId)
    if (!row || !this.element.contains(row)) return null
    if (!row.matches('[data-receipt-form-target~="itemRow"]')) return null

    return row
  }

  reviewItemRowVisible (row) {
    if (!row?.isConnected) return false
    if (row.style.display === 'none') return false

    const rowContainer = this.itemRowContainer(row)
    if (rowContainer !== row && rowContainer.style.display === 'none') return false

    const destroyField = row.querySelector('[data-receipt-form-target="destroyField"]')
    return destroyField?.value !== '1'
  }

  expandAdjustmentDetailsFromHash ({ scroll = true } = {}) {
    const targetId = this.currentReviewTargetId()
    if (!this.reviewAdjustmentTargetId(targetId)) return false

    const expanded = this.expandAdjustmentDetailsForReviewTarget(targetId, { scroll })
    if (!expanded && scroll) this.scrollReviewAdjustmentTargetFallback()
    return expanded
  }

  expandAdjustmentDetailsForReviewTarget (targetId, { scroll = true, focus = false } = {}) {
    const row = this.reviewAdjustmentRowForTarget(targetId)
    if (!this.reviewAdjustmentRowVisible(row)) return false

    const panel = row.querySelector('[data-receipt-form-target="adjustmentDetailsPanel"]')
    const toggles = row.querySelectorAll('[data-receipt-form-target="adjustmentDetailsToggle"]')
    const icons = row.querySelectorAll('[data-receipt-form-target="adjustmentDetailsIcon"]')
    if (!panel) return false

    this.setAdjustmentDetailsOpen({ row, panel, toggles, icons, open: true })
    if (scroll) this.scrollReviewTargetIntoView(row)
    if (focus) this.focusVisibleAdjustmentDetailsToggle(row)

    return true
  }

  reviewAdjustmentRowForTarget (targetId) {
    const rows = this.adjustmentRowTargets.filter((row) => (
      row.id === targetId &&
      this.element.contains(row) &&
      row.matches('[data-receipt-review-adjustment-row="true"]')
    ))

    return rows.length === 1 ? rows[0] : null
  }

  reviewAdjustmentRowVisible (row) {
    if (!row?.isConnected) return false
    if (row.style.display === 'none') return false

    const rowContainer = this.adjustmentRowContainer(row)
    if (rowContainer !== row && rowContainer.style.display === 'none') return false

    const destroyField = row.querySelector('[data-receipt-form-target="adjustmentDestroyField"]')
    return destroyField?.value !== '1'
  }

  focusVisibleAdjustmentDetailsToggle (row) {
    window.requestAnimationFrame(() => {
      if (!row?.isConnected || !this.element.contains(row)) return

      const toggle = Array.from(
        row.querySelectorAll('[data-receipt-form-target="adjustmentDetailsToggle"]')
      ).find((candidate) => this.reviewTargetToggleVisible(candidate))
      if (!toggle) return

      toggle.focus({ preventScroll: true })
    })
  }

  reviewTargetToggleVisible (toggle) {
    if (!toggle || toggle.hidden) return false

    const style = window.getComputedStyle(toggle)
    if (style.display === 'none' || style.visibility === 'hidden') return false

    return toggle.getClientRects().length > 0
  }

  pushReviewTargetHash (targetId) {
    if (!targetId || typeof window.history?.pushState !== 'function') return

    const hash = reviewTargetHash(targetId)
    if (window.location.hash === hash) return

    window.history.pushState(null, '', hash)
  }

  navigateReviewTargetHash (targetId) {
    if (!targetId) return

    const hash = reviewTargetHash(targetId)
    if (window.location.hash === hash) return

    if (typeof window.history?.pushState === 'function') {
      window.history.pushState(window.history.state, '', hash)
      return
    }

    window.location.hash = hash
  }

  scheduleReviewTargetScroll (target, { block = 'center', delay = REVIEW_TARGET_CLICK_SCROLL_DELAY_MS } = {}) {
    this.clearReviewTargetScrollTimer()
    if (!target || typeof target.scrollIntoView !== 'function') return

    this.reviewTargetScrollTimer = window.setTimeout(() => {
      this.reviewTargetScrollTimer = null
      this.scrollReviewTargetIntoView(target, { block })
    }, delay)
  }

  clearReviewTargetScrollTimer () {
    if (this.reviewTargetScrollTimer == null) return

    window.clearTimeout(this.reviewTargetScrollTimer)
    this.reviewTargetScrollTimer = null
  }

  scrollReviewTargetFallback (targetId = this.reviewItemsTargetValue) {
    const fallback = document.getElementById(targetId) || document.getElementById(this.reviewItemsTargetValue)
    this.scrollReviewTargetIntoView(fallback, { block: 'start' })
  }

  scrollReviewAdjustmentTargetFallback () {
    const fallback = document.getElementById(this.reviewAdjustmentsTargetValue)
    this.scrollReviewTargetIntoView(fallback, { block: 'start' })
  }

  scrollReviewTargetIntoView (target, { block = 'center' } = {}) {
    if (!target || typeof target.scrollIntoView !== 'function') return

    window.requestAnimationFrame(() => {
      target.scrollIntoView({ behavior: 'smooth', block, inline: 'nearest' })
    })
  }

  toggleItemDetails (event) {
    event.preventDefault()

    const toggle = event.currentTarget
    const row = toggle.closest('[data-receipt-form-target="itemRow"]')
    if (!row) return

    const panel = row.querySelector('[data-receipt-form-target="itemDetailsPanel"]')
    const toggles = row.querySelectorAll('[data-receipt-form-target="itemDetailsToggle"]')
    const icons = row.querySelectorAll('[data-receipt-form-target="itemDetailsIcon"]')
    if (!panel) return

    const willOpen = !this.itemDetailsPanelOpen(panel)
    if (willOpen) this.hideLineTotalTooltipFor(row)

    this.setItemDetailsOpen({ row, panel, toggles, icons, open: willOpen })
  }

  syncItemDetailsPanels () {
    this.itemRowTargets.forEach((row) => {
      const panel = row.querySelector('[data-receipt-form-target="itemDetailsPanel"]')
      const toggles = row.querySelectorAll('[data-receipt-form-target="itemDetailsToggle"]')
      const icons = row.querySelectorAll('[data-receipt-form-target="itemDetailsIcon"]')
      const open = row.classList.contains('receipt-form-item-details-open') || this.itemDetailsPanelOpen(panel)

      this.setItemDetailsOpen({ row, panel, toggles, icons, open })
    })
  }

  revealInvalidItemSourceRows () {
    if (!this.hasInvalidItemSourceSummaryTarget || this.invalidItemSourceSummaryTarget.hidden) return

    this.itemRowTargets.forEach((row) => {
      if (!this.reviewItemRowVisible(row)) return

      const panel = row.querySelector('[data-receipt-form-target="itemDetailsPanel"]')
      const toggles = row.querySelectorAll('[data-receipt-form-target="itemDetailsToggle"]')
      const icons = row.querySelectorAll('[data-receipt-form-target="itemDetailsIcon"]')
      this.setItemDetailsOpen({ row, panel, toggles, icons, open: true })
    })

    window.requestAnimationFrame(() => {
      if (!this.invalidItemSourceSummaryTarget?.isConnected) return

      this.invalidItemSourceSummaryTarget.focus({ preventScroll: true })
      this.scrollReviewTargetIntoView(this.invalidItemSourceSummaryTarget, { block: 'start' })
    })
  }

  handleInvalidItemField (event) {
    const row = event.target?.closest?.('[data-receipt-form-target="itemRow"]')
    if (!row) return

    const panel = row.querySelector('[data-receipt-form-target="itemDetailsPanel"]')
    if (!panel?.contains(event.target) || this.itemDetailsPanelOpen(panel)) return

    const toggles = row.querySelectorAll('[data-receipt-form-target="itemDetailsToggle"]')
    const icons = row.querySelectorAll('[data-receipt-form-target="itemDetailsIcon"]')
    this.setItemDetailsOpen({ row, panel, toggles, icons, open: true })
  }

  syncAdjustmentDetailsPanels () {
    this.adjustmentRowTargets.forEach((row) => {
      const panel = row.querySelector('[data-receipt-form-target="adjustmentDetailsPanel"]')
      const toggles = row.querySelectorAll('[data-receipt-form-target="adjustmentDetailsToggle"]')
      const icons = row.querySelectorAll('[data-receipt-form-target="adjustmentDetailsIcon"]')
      const open = row.classList.contains('receipt-form-adjustment-details-open') || this.adjustmentDetailsPanelOpen(panel)

      this.setAdjustmentDetailsOpen({ row, panel, toggles, icons, open })
    })
  }

  setItemDetailsOpen ({ row, panel, toggles, icons, open }) {
    if (!panel) return

    panel.classList.toggle('is-open', open)
    panel.toggleAttribute('inert', !open)
    panel.setAttribute('aria-hidden', String(!open))
    row?.classList.toggle('receipt-form-item-details-open', open)

    toggles.forEach((toggle) => {
      toggle.setAttribute('aria-expanded', String(open))
    })

    icons.forEach((icon) => {
      icon.classList.toggle('rotate-180', open)
    })
  }

  itemDetailsPanelOpen (panel) {
    return Boolean(panel?.classList.contains('is-open'))
  }

  setAdjustmentDetailsOpen ({ row, panel, toggles, icons, open }) {
    if (!panel) return

    panel.classList.toggle('is-open', open)
    panel.toggleAttribute('inert', !open)
    panel.setAttribute('aria-hidden', String(!open))
    row?.classList.toggle('receipt-form-adjustment-details-open', open)

    toggles.forEach((toggle) => {
      toggle.setAttribute('aria-expanded', String(open))
    })

    icons.forEach((icon) => {
      icon.classList.toggle('rotate-180', open)
    })
  }

  adjustmentDetailsPanelOpen (panel) {
    return Boolean(panel?.classList.contains('is-open'))
  }

  handleBeforeCache () {
    this.syncPricingSourceModes()
    this.syncItemDetailsPanels()
    this.syncAdjustmentDetailsPanels()
    this.syncAdjustmentSigns()
    this.syncAdjustmentAbsenceConfirmation()
  }

  syncAdjustmentAbsenceConfirmation () {
    if (!this.hasAdjustmentAbsenceConfirmationTarget || !this.hasAdjustmentAbsenceConfirmationFieldTarget) return

    const visible = this.adjustmentRowTargets.every((row) => (
      this.previewRowExcluded(row, 'adjustmentDestroyField')
    ))
    const panel = this.adjustmentAbsenceConfirmationTarget
    const field = this.adjustmentAbsenceConfirmationFieldTarget

    if (!visible) field.checked = false

    panel.hidden = !visible
    panel.toggleAttribute('inert', !visible)
    panel.setAttribute('aria-hidden', String(!visible))
  }

  scheduleLineTotalTooltip (event) {
    // lg未満は表示しない
    if (window.innerWidth < 1024) return

    const row = event.currentTarget
    if (row.classList.contains('receipt-form-item-details-open')) {
      this.hideLineTotalTooltipFor(row)
      return
    }

    const tooltip = this.lineTotalTooltipFor(row)

    if (!tooltip) return

    this.hideLineTotalTooltipFor(row)
    this.clearLineTotalTooltipTimer(row)

    row.lineTotalTooltipTimer = window.setTimeout(() => {
      this.showLineTotalTooltipFor(row)
    }, this.lineTotalTooltipDelay)
  }

  hideLineTotalTooltip (event) {
    const row = event.currentTarget.closest('[data-receipt-form-target="itemRow"]') || event.currentTarget
    this.hideLineTotalTooltipFor(row)
  }

  hideLineTotalTooltipOnFocus (event) {
    const row = event.currentTarget.closest('[data-receipt-form-target="itemRow"]') || event.currentTarget
    this.hideLineTotalTooltipFor(row)
  }

  showLineTotalTooltipFor (row) {
    // lg未満は表示しない
    if (window.innerWidth < 1024) return
    if (row?.classList.contains('receipt-form-item-details-open')) {
      this.hideLineTotalTooltipFor(row)
      return
    }

    const tooltip = this.lineTotalTooltipFor(row)

    if (!tooltip) return

    tooltip.classList.remove('hidden', 'opacity-0')
    tooltip.classList.add('opacity-100')
  }

  hideLineTotalTooltipFor (row) {
    const tooltip = this.lineTotalTooltipFor(row)

    this.clearLineTotalTooltipTimer(row)

    if (!tooltip) return

    tooltip.classList.add('hidden', 'opacity-0')
    tooltip.classList.remove('opacity-100')
  }

  clearLineTotalTooltipTimer (row) {
    if (!row?.lineTotalTooltipTimer) return

    window.clearTimeout(row.lineTotalTooltipTimer)
    row.lineTotalTooltipTimer = null
  }

  lineTotalTooltipFor (row) {
    return row?.querySelector('[data-receipt-form-target="lineTotalTooltip"]')
  }

  recalculate ({ pricingSourceChangedRow } = {}) {
    this.itemRowTargets.forEach((row) => {
      this.syncPricingSourceSummaryForRow(row, this.pricingSourceModeForRow(row))
    })
    if (!this.previewNumericInputsValid()) {
      this.renderUnavailablePreview()
      return
    }

    let subtotalSum = 0
    let taxSum = 0
    let total = 0
    let paymentAdjustmentTotal = 0
    const taxRates = new Set()
    const sourceAwareTaxGroups = new Map()
    const externalTax = this.usesExternalTax()
    const amountBearingItemTaxRates = new Set()
    let amountBearingItemCount = 0
    let hasItemAmountSource = false
    let allAmountBearingItemsHaveTaxRate = true
    let itemPreviewUnavailable = false
    const purchaseInputsChanged = this.purchaseInputsChangedForPreview()

    this.itemRowTargets.forEach((row) => {
      if (this.previewRowExcluded(row, 'destroyField')) return

      const quantityInput = row.querySelector('[data-receipt-form-target="quantityInput"]')
      const quantityUnitInput = row.querySelector('[data-receipt-form-target="quantityUnitInput"]')
      const priceInput = row.querySelector('[data-receipt-form-target="priceInput"]')
      const discountRateInput = row.querySelector('[data-receipt-form-target="discountRateInput"]')
      const taxRateInput = row.querySelector('[data-receipt-form-target="taxRateInput"]')
      const lineTotalDisplays = row.querySelectorAll('[data-receipt-form-target="lineTotalDisplay"]')
      const lineTotalInput = row.querySelector('[data-receipt-form-target="lineTotalInput"]')
      const originalLineTotalInput = row.querySelector('[data-receipt-form-target="originalLineTotalInput"]')

      let quantity = this.clampNumber(this.parseDecimalInput(quantityInput?.value), 0, 9999)
      if (quantity <= 0) quantity = 1
      const priceInputPresent = String(priceInput?.value ?? '').trim() !== ''
      const price = this.clampNumber(this.parseIntegerInput(priceInput?.value), 0, this.receiptItemPriceMaxValue)
      const discountRatePercent = this.parseDiscountRateInput(discountRateInput?.value)
      const itemTaxRateInputPresent = String(taxRateInput?.value ?? '').trim() !== ''
      let taxRatePercent = this.clampNumber(this.parseDecimalInput(taxRateInput?.value), 0, 100)
      const quantityUnit = quantityUnitInput?.value
      const pricingSourceMode = this.pricingSourceModeForRow(row)
      const itemSource = this.itemPreviewSourceFor({
        row,
        pricingSourceMode,
        quantity,
        quantityInput,
        quantityUnit,
        price,
        priceInputPresent,
        lineTotalInput
      })
      if (itemSource.invalid) {
        itemPreviewUnavailable = true
        return
      }
      const itemAmountSourcePresent = itemSource.present
      hasItemAmountSource ||= itemAmountSourcePresent

      const originalLineTotal = itemSource.originalLineTotal
      if (originalLineTotal < 0 || originalLineTotal > this.receiptItemLineTotalMaxValue) {
        itemPreviewUnavailable = true
        return
      }
      const lineTotal = itemAmountSourcePresent
        ? this.lineTotalFor({
          originalLineTotal,
          discountRatePercent,
          discountRateInput,
          lineTotalInput,
          sourceModeChanged: pricingSourceChangedRow === row
        })
        : 0
      if (lineTotal < 0 || lineTotal > this.receiptItemLineTotalMaxValue) {
        itemPreviewUnavailable = true
        return
      }
      const itemTaxBasis = this.itemPreviewTaxBasis({ row, pricingSourceMode })
      let itemTaxRateAvailable = itemTaxRateInputPresent
      if (pricingSourceMode === 'reference_quantity_price' && itemTaxBasis === 'net' &&
        !itemTaxRateInputPresent && !purchaseInputsChanged) {
        const fallbackTaxRate = String(this.referenceProjectionFallbackTaxRateValue ?? '').trim()
        itemTaxRateAvailable = fallbackTaxRate !== ''
        taxRatePercent = this.clampNumber(this.parseDecimalInput(fallbackTaxRate), 0, 100)
      }
      if (itemTaxBasis === 'unavailable' || (
        pricingSourceMode === 'reference_quantity_price' && itemTaxBasis === 'net' && !itemTaxRateAvailable
      )) {
        itemPreviewUnavailable = true
        return
      }
      if (taxRatePercent > 0) taxRates.add(taxRatePercent)
      const projectedLineTotal = this.projectedItemLineTotal({
        lineTotal,
        taxRatePercent,
        taxBasis: itemTaxBasis
      })
      if (projectedLineTotal < 0) {
        itemPreviewUnavailable = true
        return
      }
      if (lineTotal > 0) {
        amountBearingItemCount += 1
        if (!itemTaxRateAvailable) {
          allAmountBearingItemsHaveTaxRate = false
        } else {
          amountBearingItemTaxRates.add(taxRatePercent)
        }
      }
      this.addSourceAwareTaxAmount(sourceAwareTaxGroups, {
        amount: lineTotal,
        taxRatePercent,
        taxBasis: itemTaxBasis
      })

      // 表示更新（PCツールチップ / スマホ小計など、同一行内の複数表示に対応）
      lineTotalDisplays.forEach((lineTotalDisplay) => {
        const withLabel = Boolean(lineTotalDisplay.closest('[data-receipt-form-target="lineTotalTooltip"]'))
        this.animateLineTotal(lineTotalDisplay, projectedLineTotal, { withLabel })
      })

      this.syncLineTotalState({
        lineTotalInput,
        originalLineTotalInput,
        itemAmountSourcePresent,
        priceInputPresent,
        quantityUnit,
        pricingSourceMode,
        originalLineTotal,
        lineTotal
      })
    })

    if (itemPreviewUnavailable) {
      this.renderUnavailablePreview()
      return
    }

    const inheritedAdjustmentTaxRate = this.inheritedAdjustmentTaxRate({
      amountBearingItemCount,
      allAmountBearingItemsHaveTaxRate,
      amountBearingItemTaxRates,
      purchaseInputsChanged
    })

    this.adjustmentRowTargets.forEach((row) => {
      if (this.previewRowExcluded(row, 'adjustmentDestroyField')) return

      this.syncAdjustmentSignForRow(row)

      const amountInput = row.querySelector('[data-receipt-form-target="adjustmentAmountInput"]')
      const taxRateInput = row.querySelector('[data-receipt-form-target="adjustmentTaxRateInput"]')
      const effect = this.adjustmentEffectForRow(row)
      const sign = this.adjustmentSignForRow(row)
      const amount = this.clampNumber(this.parseIntegerInput(amountInput?.value), 0, this.receiptAdjustmentAmountMaxValue)
      const explicitTaxRate = String(taxRateInput?.value ?? '').trim() !== ''
      const submittedTaxRatePercent = this.clampNumber(this.parseDecimalInput(taxRateInput?.value), 0, 100)
      const taxRatePercent = explicitTaxRate ? submittedTaxRatePercent : inheritedAdjustmentTaxRate
      if (amount <= 0) return

      if (taxRatePercent > 0 && effect !== 'payment_adjustment') {
        taxRates.add(taxRatePercent)
      }

      const signedAmount = sign === 'surcharge' ? amount : -amount
      if (effect === 'payment_adjustment') {
        paymentAdjustmentTotal += signedAmount
        return
      }

      this.addSourceAwareTaxAmount(sourceAwareTaxGroups, {
        amount: signedAmount,
        taxRatePercent,
        taxBasis: externalTax ? 'net' : 'gross'
      })
    })

    const sourceAwareProjection = this.projectSourceAwareTaxGroups(sourceAwareTaxGroups)
    subtotalSum = sourceAwareProjection.subtotal
    taxSum = sourceAwareProjection.tax
    total = sourceAwareProjection.total

    const preserveInitialReceiptAmounts = this.preserveInitialReceiptAmountsForPreview({ hasItemAmountSource })
    if (preserveInitialReceiptAmounts) {
      subtotalSum = this.initialReceiptAmounts.subtotal
      taxSum = this.initialReceiptAmounts.tax
      total = this.initialReceiptAmounts.total
    }

    const rawPurchaseTotal = total
    if ([subtotalSum, taxSum, total].some((amount) => amount < 0)) {
      subtotalSum = 0
      taxSum = 0
      total = 0
    } else if (total > this.receiptTotalAmountMaxValue ||
      subtotalSum > this.receiptTotalAmountMaxValue ||
      taxSum > this.receiptTaxAmountMaxValue) {
      this.renderUnavailablePreview()
      return
    } else {
      total = Math.floor(total)
      subtotalSum = Math.floor(subtotalSum)
      taxSum = Math.floor(taxSum)
    }
    const finalPaymentTotal = rawPurchaseTotal + paymentAdjustmentTotal
    this.lastFinalPaymentTotal = finalPaymentTotal

    // 合計更新（存在する場合のみ）
    if (this.hasTotalAmountTarget) {
      this.animateAmount(this.totalAmountTarget, total)
    }

    if (this.hasSubtotalAmountTarget) {
      this.animateAmount(this.subtotalAmountTarget, subtotalSum)
    }

    if (this.hasTaxAmountTarget) {
      this.animateAmount(this.taxAmountTarget, taxSum)
    }

    if (this.hasTaxRateSummaryTarget) {
      const initialTaxRateSummary = this.initialReceiptAmounts?.taxRateSummary
      this.taxRateSummaryTarget.textContent = preserveInitialReceiptAmounts && typeof initialTaxRateSummary === 'string'
        ? initialTaxRateSummary
        : this.formatTaxRateSummary(taxRates)
    }

    this.syncPaymentAdjustmentSummary(paymentAdjustmentTotal, finalPaymentTotal)
    this.syncPaymentReconciliationSummary(this.paymentAmountSum(), finalPaymentTotal)
  }

  inheritedAdjustmentTaxRate ({ amountBearingItemCount, allAmountBearingItemsHaveTaxRate, amountBearingItemTaxRates, purchaseInputsChanged }) {
    if (amountBearingItemCount === 0 || !allAmountBearingItemsHaveTaxRate) return null
    if (amountBearingItemTaxRates.size !== 1) return null

    const [itemTaxRate] = amountBearingItemTaxRates
    if (itemTaxRate <= 0) return null

    const detailRates = !purchaseInputsChanged &&
      !this.adjustmentTaxDetailEvidenceStaleValue &&
      Array.isArray(this.adjustmentTaxDetailRatesValue)
      ? this.adjustmentTaxDetailRatesValue
      : []
    if (detailRates.length === 0) return itemTaxRate

    const parsedDetailRates = detailRates.map((rate) => {
      if (rate === null || String(rate).trim() === '') return Number.NaN

      return this.parseDecimalInput(rate)
    })
    if (parsedDetailRates.some((rate) => !Number.isFinite(rate))) return null

    const uniqueDetailRates = new Set(parsedDetailRates)
    return uniqueDetailRates.size === 1 && uniqueDetailRates.has(itemTaxRate) ? itemTaxRate : null
  }

  captureInitialPurchaseInputFingerprint () {
    const dataKey = 'receiptFormInitialPurchaseInputFingerprint'
    const storedFingerprint = this.element?.dataset?.[dataKey]
    const submittedFingerprint = this.hasInitialPurchaseInputFingerprintTarget
      ? String(this.initialPurchaseInputFingerprintTarget.value ?? '')
      : ''
    const carriedFingerprint = storedFingerprint || submittedFingerprint
    this.purchaseInputBaselineTrusted = Boolean(carriedFingerprint) || !this.purchaseInputsChangedValue
    this.initialPurchaseInputFingerprint = carriedFingerprint || this.purchaseInputFingerprint()

    if (this.purchaseInputBaselineTrusted && this.element?.dataset && !storedFingerprint) {
      this.element.dataset[dataKey] = this.initialPurchaseInputFingerprint
    }
    if (this.purchaseInputBaselineTrusted && this.hasInitialPurchaseInputFingerprintTarget) {
      this.initialPurchaseInputFingerprintTarget.value = this.initialPurchaseInputFingerprint
    }
  }

  captureInitialReceiptAmounts () {
    const dataKey = 'receiptFormInitialReceiptAmounts'
    const storedAmounts = this.element?.dataset?.[dataKey]
    if (storedAmounts) {
      try {
        const parsedAmounts = JSON.parse(storedAmounts)
        if (this.validReceiptAmounts(parsedAmounts)) {
          this.initialReceiptAmounts = parsedAmounts
          return
        }
      } catch (_) {
        // Turbo cache dataが不正な場合は現在表示から安全に取り直す。
      }
    }

    const amounts = {
      subtotal: this.hasSubtotalAmountTarget ? this.currentAmountValue(this.subtotalAmountTarget) : 0,
      tax: this.hasTaxAmountTarget ? this.currentAmountValue(this.taxAmountTarget) : 0,
      total: this.hasTotalAmountTarget ? this.currentAmountValue(this.totalAmountTarget) : 0,
      taxRateSummary: this.hasTaxRateSummaryTarget ? this.taxRateSummaryTarget.textContent : null
    }
    this.initialReceiptAmounts = amounts
    if (this.element?.dataset) this.element.dataset[dataKey] = JSON.stringify(amounts)
  }

  validReceiptAmounts (amounts) {
    return amounts && [amounts.subtotal, amounts.tax, amounts.total].every(Number.isFinite)
  }

  preserveInitialReceiptAmountsForPreview ({ hasItemAmountSource }) {
    if (hasItemAmountSource) return false
    if (!this.validReceiptAmounts(this.initialReceiptAmounts)) return false

    return !this.purchaseInputsChangedForPreview()
  }

  purchaseInputsChangedForPreview () {
    if (typeof this.initialPurchaseInputFingerprint === 'string' && this.purchaseInputBaselineTrusted !== false) {
      return this.purchaseInputFingerprint() !== this.initialPurchaseInputFingerprint
    }

    return this.purchaseInputsChangedValue
  }

  purchaseInputFingerprint () {
    const items = this.itemRowTargets
      .filter((row) => !this.previewRowExcluded(row, 'destroyField'))
      .map((row) => {
        const inputValue = (target) => row.querySelector(`[data-receipt-form-target="${target}"]`)?.value

        const lineTotalInput = row.querySelector('[data-receipt-form-target="lineTotalInput"]')
        const price = inputValue('priceInput')
        const quantityUnit = inputValue('quantityUnitInput')
        const mode = this.pricingSourceModeForRow(row)
        const sourcePresent = mode === 'reference_quantity_price'
          ? [inputValue('referencePriceAmountInput'), inputValue('referenceQuantityInput')]
              .some((value) => String(value ?? '').trim() !== '')
          : mode === 'explicit_line_total'
            ? String(inputValue('explicitLineTotalInput') ?? '').trim() !== ''
            : this.itemAmountSourcePresentFor({
              lineTotalInput,
              priceInputPresent: String(price ?? '').trim() !== '',
              quantityUnit
            })
        if (!sourcePresent) return null

        const common = [
          mode,
          this.normalizedOptionalDecimalInput(inputValue('quantityInput')),
          String(quantityUnit ?? '').trim(),
          this.normalizedOptionalDecimalInput(inputValue('discountRateInput')),
          this.normalizedOptionalDecimalInput(inputValue('taxRateInput'))
        ]
        if (mode === 'reference_quantity_price') {
          return common.concat([
            this.normalizedOptionalDecimalInput(inputValue('referencePriceAmountInput')),
            this.normalizedOptionalDecimalInput(inputValue('referenceQuantityInput')),
            String(inputValue('referenceQuantityUnitInput') ?? '').trim(),
            String(inputValue('referencePriceTaxInclusionInput') ?? '').trim()
          ])
        }
        if (mode === 'explicit_line_total') {
          return common.concat([this.normalizedOptionalIntegerInput(inputValue('explicitLineTotalInput'))])
        }

        return common.concat([
          this.normalizedOptionalIntegerInput(price),
          this.normalizedOptionalIntegerInput(inputValue('lineTotalInput'))
        ])
      })
      .filter((item) => item !== null)
    const adjustments = this.adjustmentRowTargets
      .filter((row) => !this.previewRowExcluded(row, 'adjustmentDestroyField'))
      .filter((row) => this.adjustmentEffectForRow(row) !== 'payment_adjustment')
      .map((row) => {
        const inputValue = (target) => row.querySelector(`[data-receipt-form-target="${target}"]`)?.value
        const persisted = String(row.querySelector('input[name$="[id]"]')?.value ?? '').trim() !== ''
        const labelPresent = String(row.querySelector('input[name$="[label]"]')?.value ?? '').trim() !== ''
        const amount = inputValue('adjustmentAmountInput')
        const taxRate = inputValue('adjustmentTaxRateInput')
        const meaningfulInput = labelPresent || String(amount ?? '').trim() !== '' ||
          this.parseDecimalInput(taxRate) > 0
        if (!persisted && !meaningfulInput) return null

        return [
          this.adjustmentEffectForRow(row),
          String(inputValue('adjustmentKindInput') ?? '').trim(),
          this.normalizedOptionalIntegerInput(amount),
          this.adjustmentSignForRow(row),
          this.normalizedOptionalDecimalInput(taxRate)
        ]
      })
      .filter((adjustment) => adjustment !== null)

    return JSON.stringify({ items, adjustments })
  }

  normalizedOptionalIntegerInput (value) {
    const rawValue = String(value ?? '').trim()
    if (rawValue === '') return ''

    const parsedValue = this.parseIntegerInput(rawValue)
    return Number.isFinite(parsedValue) ? String(parsedValue) : rawValue
  }

  syncAdjustmentSigns () {
    this.adjustmentRowTargets.forEach((row) => this.syncAdjustmentSignForRow(row))
  }

  syncAdjustmentEffectForRow (row) {
    if (!row) return

    row.dataset.receiptFormAdjustmentEffect = this.adjustmentEffectForRow(row)
  }

  adjustmentEffectForRow (row) {
    const kindInput = row?.querySelector('[data-receipt-form-target="adjustmentKindInput"]')
    const normalizedKind = String(kindInput?.value ?? '').trim() || 'other'
    if (this.adjustmentPaymentKindList().includes(normalizedKind)) return 'payment_adjustment'
    if (this.adjustmentPurchaseKindList().includes(normalizedKind)) return 'purchase_adjustment'

    const label = row?.querySelector('input[name$="[label]"]')?.value
    const sourcePayment = row?.dataset?.receiptFormAdjustmentSourcePayment === 'true'
    if (sourcePayment || this.adjustmentPaymentLabelMatches(label)) return 'payment_adjustment'

    const sourceNonManual = row?.dataset?.receiptFormAdjustmentSourceNonManual === 'true'
    if (normalizedKind === 'other' && sourceNonManual) return 'unknown_adjustment'

    return 'purchase_adjustment'
  }

  syncAdjustmentSignForRow (row) {
    if (!row) return

    const kindInput = row.querySelector('[data-receipt-form-target="adjustmentKindInput"]')
    const signInput = row.querySelector('[data-receipt-form-target="adjustmentSignInput"]')
    const signLabel = row.querySelector('[data-receipt-form-target="adjustmentSignLabel"]')
    const signLabelWrapper = row.querySelector('[data-receipt-form-target="adjustmentSignLabelWrapper"]')
    const signSelect = row.querySelector('[data-receipt-form-target="adjustmentSignSelect"]')
    const signSelectWrapper = row.querySelector('[data-receipt-form-target="adjustmentSignSelectWrapper"]')
    if (!signInput) return

    const kind = String(kindInput?.value ?? '')
    const other = kind === 'other'
    const sign = other ? this.validAdjustmentSign(signSelect?.value) : this.adjustmentSignForKind(kind)

    if (other) {
      signInput.disabled = true
      if (signSelect) {
        signSelect.disabled = false
        signSelect.value = sign
      }
      signLabelWrapper?.classList.add('hidden')
      signSelectWrapper?.classList.remove('hidden')
    } else {
      signInput.disabled = false
      signInput.value = sign
      if (signSelect) {
        signSelect.disabled = true
        signSelect.value = sign
      }
      signLabelWrapper?.classList.remove('hidden')
      signSelectWrapper?.classList.add('hidden')
    }

    if (signLabel) {
      signLabel.textContent = sign === 'surcharge' ? this.adjustmentSurchargeLabelValue : this.adjustmentDiscountLabelValue
    }
  }

  adjustmentSignForRow (row) {
    const kindInput = row.querySelector('[data-receipt-form-target="adjustmentKindInput"]')
    const signInput = row.querySelector('[data-receipt-form-target="adjustmentSignInput"]')
    const signSelect = row.querySelector('[data-receipt-form-target="adjustmentSignSelect"]')
    const kind = String(kindInput?.value ?? '')

    if (kind === 'other') return this.validAdjustmentSign(signSelect?.value)

    return this.validAdjustmentSign(signInput?.value) || this.adjustmentSignForKind(kind)
  }

  adjustmentSignForKind (kind) {
    const normalizedKind = String(kind ?? '').trim()
    if (this.adjustmentSurchargeKindList().includes(normalizedKind)) return 'surcharge'
    if (this.adjustmentDiscountKindList().includes(normalizedKind)) return 'discount'

    return 'surcharge'
  }

  validAdjustmentSign (sign) {
    const normalizedSign = String(sign ?? '').trim()
    return ['surcharge', 'discount'].includes(normalizedSign) ? normalizedSign : 'surcharge'
  }

  adjustmentSurchargeKindList () {
    return this.adjustmentSurchargeKindsValue
      .split(',')
      .map((kind) => kind.trim())
      .filter((kind) => kind !== '')
  }

  adjustmentDiscountKindList () {
    return this.adjustmentDiscountKindsValue
      .split(',')
      .map((kind) => kind.trim())
      .filter((kind) => kind !== '')
  }

  adjustmentPaymentKindList () {
    return this.adjustmentPaymentKindsValue
      .split(',')
      .map((kind) => kind.trim())
      .filter((kind) => kind !== '')
  }

  adjustmentPurchaseKindList () {
    return this.adjustmentPurchaseKindsValue
      .split(',')
      .map((kind) => kind.trim())
      .filter((kind) => kind !== '')
  }

  adjustmentPaymentLabelMatches (label) {
    const pattern = String(this.adjustmentPaymentLabelPatternValue ?? '')
    if (pattern === '') return false

    try {
      return new RegExp(pattern, 'i').test(String(label ?? ''))
    } catch (_error) {
      return false
    }
  }

  syncPaymentAdjustmentSummary (paymentAdjustmentTotal, finalPaymentTotal) {
    const visible = paymentAdjustmentTotal !== 0

    this.paymentAdjustmentRowTargets.forEach((row) => row.classList.toggle('hidden', !visible))
    this.finalPaymentRowTargets.forEach((row) => row.classList.toggle('hidden', !visible))

    if (this.hasPaymentAdjustmentAmountTarget) {
      const text = this.formatSignedAmount(paymentAdjustmentTotal)
      this.paymentAdjustmentAmountTarget.textContent = text
      this.paymentAdjustmentAmountTarget.title = text
    }

    if (this.hasFinalPaymentAmountTarget) {
      this.animateAmount(this.finalPaymentAmountTarget, finalPaymentTotal)
    }
  }

  syncPaymentReconciliationSummary (paymentAmountSum, finalPaymentTotal) {
    const hasPaymentRows = this.visiblePaymentRows().length > 0
    const paymentDifference = paymentAmountSum - finalPaymentTotal
    const mismatch = hasPaymentRows && paymentDifference !== 0
    const syncableMismatch = mismatch && finalPaymentTotal >= 0

    if (this.hasPaymentAmountSumTarget) {
      this.animateAmount(this.paymentAmountSumTarget, paymentAmountSum)
    }

    if (this.hasPaymentReconciliationFinalAmountTarget) {
      this.animateAmount(this.paymentReconciliationFinalAmountTarget, finalPaymentTotal)
    }

    if (this.hasPaymentDifferenceAmountTarget) {
      this.paymentDifferenceAmountTarget.textContent = this.formatPaymentDifference(paymentDifference)
      this.paymentDifferenceAmountTarget.title = this.paymentDifferenceAmountTarget.textContent.trim()
      this.syncAmountDisplayState(this.paymentDifferenceAmountTarget, paymentDifference)
    }

    this.paymentMismatchWarningTargets.forEach((warning) => warning.classList.toggle('hidden', !mismatch))
    this.syncPaymentAmountButtonTargets.forEach((button) => button.classList.toggle('hidden', !syncableMismatch))
    this.syncPaymentSummaryLayout()
  }

  syncPaymentSummaryLayout () {
    if (!this.hasPaymentSummaryGridTarget) return

    const amountTargets = [
      this.hasPaymentAmountSumTarget ? this.paymentAmountSumTarget : null,
      this.hasPaymentReconciliationFinalAmountTarget ? this.paymentReconciliationFinalAmountTarget : null,
      this.hasPaymentDifferenceAmountTarget ? this.paymentDifferenceAmountTarget : null
    ].filter(Boolean)
    const maxLength = amountTargets.reduce((length, target) => {
      return Math.max(length, target.textContent.trim().length)
    }, 0)

    this.paymentSummaryGridTarget.classList.toggle('is-stacked', maxLength >= 14)
  }

  paymentAmountSum () {
    return this.visiblePaymentRows().reduce((sum, row) => {
      const amountInput = row.querySelector('[data-receipt-form-target="paymentAmountInput"]')
      const amount = this.clampNumber(this.parseIntegerInput(amountInput?.value), 0, this.receiptPaymentAmountMaxValue)

      return sum + amount
    }, 0)
  }

  visiblePaymentRows () {
    return this.paymentRowTargets.filter((row) => !this.previewRowExcluded(row, 'paymentDestroyField'))
  }

  syncPaymentAmountToFinal (event) {
    event.preventDefault()

    const rows = this.visiblePaymentRows()
    if (rows.length === 0) return

    const finalPaymentTotal = this.currentFinalPaymentTotal()
    if (finalPaymentTotal < 0) return

    const currentPaymentSum = this.paymentAmountSum()
    const delta = finalPaymentTotal - currentPaymentSum
    const firstInput = rows[0].querySelector('[data-receipt-form-target="paymentAmountInput"]')
    if (!firstInput) return

    const firstAmount = this.parseIntegerInput(firstInput.value)
    if (!Number.isFinite(firstAmount)) return

    const nextFirstAmount = firstAmount + delta

    if (nextFirstAmount >= 0) {
      firstInput.value = nextFirstAmount
    } else {
      firstInput.value = finalPaymentTotal
      rows.slice(1).forEach((row) => {
        const amountInput = row.querySelector('[data-receipt-form-target="paymentAmountInput"]')
        if (amountInput) amountInput.value = 0
      })
    }

    this.recalculate()
  }

  currentFinalPaymentTotal () {
    if (Number.isFinite(this.lastFinalPaymentTotal)) return this.lastFinalPaymentTotal
    if (this.hasFinalPaymentAmountTarget) return this.currentAmountValue(this.finalPaymentAmountTarget)
    if (this.hasPaymentReconciliationFinalAmountTarget) return this.currentAmountValue(this.paymentReconciliationFinalAmountTarget)
    if (this.hasTotalAmountTarget) return this.currentAmountValue(this.totalAmountTarget)

    return 0
  }

  animateLineTotal (target, nextValue, { withLabel = false } = {}) {
    const duration = 250
    const startValue = this.currentAmountValue(target)
    const endValue = Math.floor(nextValue)
    const requestedAt = performance.now()
    const renderImmediately = this.shouldRenderAmountImmediately(target, requestedAt)
    const animationToken = this.startAmountAnimation(target)

    const render = (value) => {
      const displayValue = Math.floor(value)
      const amountText = `¥${this.formatNumber(displayValue)}`
      const text = withLabel ? `${this.subtotalLabelValue} ${amountText}` : amountText

      target.textContent = text
      target.title = text
      this.syncAmountDisplayState(target, displayValue)
    }

    if (startValue === endValue || renderImmediately) {
      render(endValue)
      this.finishAmountAnimation(target, animationToken, endValue)
      return
    }

    const startedAt = requestedAt

    const tick = (currentTime) => {
      if (!this.isCurrentAmountAnimation(target, animationToken)) return

      const progress = Math.min((currentTime - startedAt) / duration, 1)
      const easedProgress = this.easeOutCubic(progress)
      const currentValue = startValue + (endValue - startValue) * easedProgress

      render(currentValue)

      if (progress < 1) {
        target.amountAnimationFrame = requestAnimationFrame(tick)
      } else {
        render(endValue)
        this.finishAmountAnimation(target, animationToken, endValue)
      }
    }

    target.amountAnimationFrame = requestAnimationFrame(tick)
  }

  normalizeRoundingMode (value) {
    return normalizeRoundingMode(value)
  }

  formatSignedAmount (value) {
    return formatSignedAmount(value)
  }

  formatPaymentDifference (value) {
    return formatPaymentDifference(value)
  }

  usesExternalTax () {
    return this.receiptTaxBasisValue === 'external'
  }

  externalTaxTotal (taxGroups) {
    return externalTaxTotal(taxGroups, this.roundingModeValue)
  }

  internalTaxTotal (taxGroups) {
    return internalTaxTotal(taxGroups, this.roundingModeValue)
  }

  roundLineAmount (value) {
    return roundLineAmount(value)
  }

  originalLineTotalFor ({ quantity, price, priceInputPresent, quantityUnit, lineTotalInput }) {
    if (this.recalculatesQuantityUnit(quantityUnit)) {
      return priceInputPresent
        ? this.roundLineAmount(quantity * price)
        : this.persistedOriginalLineTotalInputValue(lineTotalInput)
    }

    return this.workingOriginalLineTotalInputValue(lineTotalInput)
  }

  itemPreviewSourceFor ({
    row,
    pricingSourceMode,
    quantity,
    quantityInput,
    quantityUnit,
    price,
    priceInputPresent,
    lineTotalInput
  }) {
    if (pricingSourceMode === 'reference_quantity_price') {
      const referencePriceAmount = row.querySelector(
        '[data-receipt-form-target="referencePriceAmountInput"]'
      )?.value
      const referenceQuantity = row.querySelector(
        '[data-receipt-form-target="referenceQuantityInput"]'
      )?.value
      const sourceStarted = [referencePriceAmount, referenceQuantity]
        .some((value) => String(value ?? '').trim() !== '')
      if (!sourceStarted) return { present: false, originalLineTotal: 0 }

      const extension = referenceItemExtension({
        referencePricingContract: this.referencePricingContractValue,
        referencePriceAmount,
        referenceQuantity,
        referenceUnitCode: row.querySelector('[data-receipt-form-target="referenceQuantityUnitInput"]')?.value,
        purchasedQuantity: quantityInput?.value,
        purchasedUnitCode: quantityUnit
      })

      return extension && extension.projectedAmount <= this.receiptItemLineTotalMaxValue
        ? { present: true, originalLineTotal: extension.projectedAmount }
        : { present: false, originalLineTotal: 0, invalid: true }
    }

    if (pricingSourceMode === 'explicit_line_total') {
      const explicitInput = row.querySelector('[data-receipt-form-target="explicitLineTotalInput"]')
      const present = String(explicitInput?.value ?? '').trim() !== ''
      return {
        present,
        originalLineTotal: present ? this.parseIntegerInput(explicitInput.value) : 0,
        invalid: !present || !Number.isFinite(this.parseIntegerInput(explicitInput?.value))
      }
    }

    if (pricingSourceMode === 'count_unit_price') {
      if (!priceInputPresent) return { present: false, originalLineTotal: 0 }
      if (!this.recalculatesQuantityUnit(quantityUnit) || !Number.isInteger(quantity)) {
        return { present: false, originalLineTotal: 0, invalid: true }
      }

      const originalLineTotal = this.roundLineAmount(quantity * price)
      return originalLineTotal <= this.receiptItemLineTotalMaxValue
        ? { present: true, originalLineTotal }
        : { present: false, originalLineTotal: 0, invalid: true }
    }

    const present = this.itemAmountSourcePresentFor({
      lineTotalInput,
      priceInputPresent,
      quantityUnit
    })
    return {
      present,
      originalLineTotal: this.originalLineTotalFor({
        quantity,
        price,
        priceInputPresent,
        quantityUnit,
        lineTotalInput
      })
    }
  }

  itemPreviewTaxBasis ({ row, pricingSourceMode }) {
    if (pricingSourceMode === 'reference_quantity_price') {
      const taxInclusion = row.querySelector(
        '[data-receipt-form-target="referencePriceTaxInclusionInput"]'
      )?.value
      if (taxInclusion === 'net') return 'net'
      if (taxInclusion === 'gross') return 'gross'

      return 'unavailable'
    }
    if (pricingSourceMode === 'explicit_line_total') return 'gross'

    return this.usesExternalTax() ? 'net' : 'gross'
  }

  projectedItemLineTotal ({ lineTotal, taxRatePercent, taxBasis }) {
    if (taxBasis !== 'net' || taxRatePercent <= 0) return lineTotal

    return lineTotal + this.externalTaxTotal(new Map([[taxRatePercent, lineTotal]]))
  }

  addSourceAwareTaxAmount (groups, { amount, taxRatePercent, taxBasis }) {
    const key = `${taxRatePercent}:${taxBasis}`
    const group = groups.get(key) || { amount: 0, taxRatePercent, taxBasis }
    group.amount += amount
    groups.set(key, group)
  }

  projectSourceAwareTaxGroups (groups) {
    let subtotal = 0
    let tax = 0
    let total = 0

    groups.forEach((group) => {
      const rateGroups = new Map([[group.taxRatePercent, group.amount]])
      if (group.taxBasis === 'net') {
        const groupTax = this.externalTaxTotal(rateGroups)
        subtotal += group.amount
        tax += groupTax
        total += group.amount + groupTax
      } else {
        const groupTax = this.internalTaxTotal(rateGroups)
        subtotal += group.amount - groupTax
        tax += groupTax
        total += group.amount
      }
    })

    return { subtotal, tax, total }
  }

  discountedLineTotalFor (originalLineTotal, discountRatePercent) {
    return discountedLineTotal(originalLineTotal, discountRatePercent, this.discountRoundingModeValue)
  }

  lineTotalFor ({
    originalLineTotal,
    discountRatePercent,
    discountRateInput,
    lineTotalInput,
    sourceModeChanged = false
  }) {
    if (!sourceModeChanged && this.shouldPreserveExistingLineTotal({
      originalLineTotal,
      discountRateInput,
      lineTotalInput
    })) {
      return this.preservedLineTotalInputValue(lineTotalInput)
    }

    return this.discountedLineTotalFor(originalLineTotal, discountRatePercent)
  }

  shouldPreserveExistingLineTotal ({ originalLineTotal, discountRateInput, lineTotalInput }) {
    if (!lineTotalInput) return false
    if (this.discountRateWasEdited(discountRateInput)) return false

    const persistedOriginalLineTotal = this.persistedOriginalLineTotalInputValue(lineTotalInput)
    if (originalLineTotal !== persistedOriginalLineTotal) return false

    return String(lineTotalInput.value ?? '').trim() !== ''
  }

  discountRateWasEdited (discountRateInput) {
    if (!discountRateInput) return false

    return this.normalizedOptionalDecimalInput(discountRateInput.value) !==
      this.normalizedOptionalDecimalInput(discountRateInput.dataset.originalDiscountRate)
  }

  normalizedOptionalDecimalInput (value) {
    return normalizedOptionalDecimalInput(value)
  }

  lineTotalInputValue (lineTotalInput) {
    return this.parseIntegerInput(lineTotalInput?.value)
  }

  preservedLineTotalInputValue (lineTotalInput) {
    const savedValue = lineTotalInput?.dataset.originalSavedLineTotal
    if (String(savedValue ?? '').trim() !== '') {
      return this.parseIntegerInput(savedValue)
    }

    return this.lineTotalInputValue(lineTotalInput)
  }

  persistedOriginalLineTotalInputValue (lineTotalInput) {
    return this.parseIntegerInput(lineTotalInput?.dataset.originalLineTotal || lineTotalInput?.value)
  }

  workingOriginalLineTotalInputValue (lineTotalInput) {
    return this.parseIntegerInput(
      lineTotalInput?.dataset.workingOriginalLineTotal ||
      lineTotalInput?.dataset.originalLineTotal ||
      lineTotalInput?.value
    )
  }

  itemAmountSourcePresentFor ({ lineTotalInput, priceInputPresent, quantityUnit }) {
    if (priceInputPresent) return true

    const persistedSourcePresent = [
      lineTotalInput?.dataset.originalLineTotal,
      lineTotalInput?.dataset.originalSavedLineTotal
    ].some((value) => String(value ?? '').trim() !== '')
    if (persistedSourcePresent) return true

    return !this.recalculatesQuantityUnit(quantityUnit) &&
      String(lineTotalInput?.dataset.workingOriginalLineTotal ?? '').trim() !== ''
  }

  syncLineTotalState ({
    lineTotalInput,
    originalLineTotalInput,
    itemAmountSourcePresent,
    priceInputPresent,
    quantityUnit,
    pricingSourceMode,
    originalLineTotal,
    lineTotal
  }) {
    if (!lineTotalInput) return
    if (!itemAmountSourcePresent) {
      lineTotalInput.value = ''
      if (originalLineTotalInput) originalLineTotalInput.value = ''
      delete lineTotalInput.dataset.workingOriginalLineTotal
      return
    }

    lineTotalInput.value = lineTotal
    if (originalLineTotalInput) originalLineTotalInput.value = originalLineTotal

    if (pricingSourceMode === 'reference_quantity_price' || pricingSourceMode === 'explicit_line_total') {
      lineTotalInput.dataset.workingOriginalLineTotal = String(originalLineTotal)
    } else if (this.recalculatesQuantityUnit(quantityUnit)) {
      if (priceInputPresent) {
        lineTotalInput.dataset.workingOriginalLineTotal = String(originalLineTotal)
      } else {
        delete lineTotalInput.dataset.workingOriginalLineTotal
      }
    }
  }

  recalculatesQuantityUnit (unit) {
    return this.countableQuantityUnits().includes(String(unit ?? '').trim())
  }

  countableQuantityUnits () {
    return this.quantityUnitList(this.countableQuantityUnitsValue)
  }

  syncInitialPricingPreviews () {
    const activeRows = this.itemRowTargets.filter((row) => !this.previewRowExcluded(row, 'destroyField'))
    const missingExplicitSourceRows = activeRows.filter((row) => this.explicitLineTotalSourceMissingForRow(row))
    if (missingExplicitSourceRows.length > 0) {
      this.renderUnavailablePreview()
      return
    }
    if (!activeRows.some((row) => this.pricingSourceModeForRow(row) === 'reference_quantity_price')) return

    this.recalculate()
  }

  explicitLineTotalSourceMissingForRow (row) {
    if (row?.dataset?.receiptFormExplicitLineTotalSourceMissing !== 'true') return false
    if (this.pricingSourceModeForRow(row) !== 'explicit_line_total') return false

    const input = row.querySelector('[data-receipt-form-target="explicitLineTotalInput"]')
    return String(input?.value ?? '').trim() === ''
  }

  syncQuantityInputSteps () {
    this.quantityUnitInputTargets.forEach((unitSelect) => {
      this.syncQuantityInputStepForUnitSelect(unitSelect, 'quantityInput')
    })
    this.referenceQuantityUnitInputTargets.forEach((unitSelect) => {
      this.syncQuantityInputStepForUnitSelect(unitSelect, 'referenceQuantityInput')
    })
  }

  syncQuantityInputStepForUnitSelect (unitSelect, quantityTarget = 'quantityInput') {
    const row = unitSelect.closest('[data-receipt-form-target="itemRow"]')
    if (!row) return

    const quantityInput = row.querySelector(`[data-receipt-form-target="${quantityTarget}"]`)
    if (!quantityInput) return

    const decimalAllowed = this.decimalQuantityUnit(unitSelect.value)
    quantityInput.step = decimalAllowed ? this.decimalQuantityStepValue : this.integerQuantityStepValue
    quantityInput.inputMode = decimalAllowed ? 'decimal' : 'numeric'
  }

  decimalQuantityUnit (unit) {
    return this.decimalQuantityUnitList().includes(String(unit ?? '').trim())
  }

  decimalQuantityUnitList () {
    return this.quantityUnitList(this.decimalQuantityUnitsValue)
  }

  quantityUnitList (value) {
    return quantityUnitList(value)
  }

  formatNumber (num) {
    return formatNumber(num)
  }

  clampNumber (value, min, max) {
    return clampNumber(value, min, max)
  }

  parseIntegerInput (value) {
    return parseIntegerInput(value)
  }

  parseDecimalInput (value) {
    return parseDecimalInput(value)
  }

  normalizeNumericInputText (value) {
    return normalizeNumericInputText(value)
  }

  parseDiscountRateInput (value) {
    return parseDiscountRateInput(value)
  }

  previewNumericInputsValid () {
    const itemsValid = this.itemRowTargets.every((row) => {
      if (this.previewRowExcluded(row, 'destroyField')) return true

      const quantityInput = row.querySelector('[data-receipt-form-target="quantityInput"]')
      const quantityUnitInput = row.querySelector('[data-receipt-form-target="quantityUnitInput"]')
      const priceInput = row.querySelector('[data-receipt-form-target="priceInput"]')
      const discountRateInput = row.querySelector('[data-receipt-form-target="discountRateInput"]')
      const taxRateInput = row.querySelector('[data-receipt-form-target="taxRateInput"]')
      const pricingSourceMode = this.pricingSourceModeForRow(row)
      const quantity = this.previewInputValue(quantityInput, 'decimal')
      const referencePriceAmountInput = row.querySelector(
        '[data-receipt-form-target="referencePriceAmountInput"]'
      )
      const referenceQuantityInput = row.querySelector(
        '[data-receipt-form-target="referenceQuantityInput"]'
      )
      const explicitLineTotalInput = row.querySelector(
        '[data-receipt-form-target="explicitLineTotalInput"]'
      )
      const modeSourceValid = this.pricingSourceModeValid(pricingSourceMode, {
        count: () => this.previewInputInRange(
          priceInput,
          'integer',
          { minimum: 0, maximum: this.receiptItemPriceMaxValue }
        ),
        reference: () => this.previewInputInRange(
          referencePriceAmountInput,
          'decimal',
          { minimum: 0, maximum: 999999999999 }
        ) && this.previewInputInRange(
          referenceQuantityInput,
          'decimal',
          { minimum: 0, maximum: 9999.999, exclusiveMinimum: true }
        ),
        explicit: () => this.previewInputInRange(
          explicitLineTotalInput,
          'integer',
          { minimum: 0, maximum: this.receiptItemLineTotalMaxValue }
        )
      })

      return quantity !== null &&
        this.previewValueInRange(quantity, { minimum: 0, maximum: 9999.999, exclusiveMinimum: true }) &&
        (this.decimalQuantityUnit(quantityUnitInput?.value) || !Number.isFinite(quantity) || Number.isInteger(quantity)) &&
        modeSourceValid &&
        this.previewInputInRange(discountRateInput, 'decimal', { minimum: 0, maximum: 100 }) &&
        this.previewInputInRange(taxRateInput, 'decimal', { minimum: 0, maximum: 100 })
    })

    if (!itemsValid) return false

    const adjustmentsValid = this.adjustmentRowTargets.every((row) => {
      if (this.previewRowExcluded(row, 'adjustmentDestroyField')) return true

      const amountInput = row.querySelector('[data-receipt-form-target="adjustmentAmountInput"]')
      const taxRateInput = row.querySelector('[data-receipt-form-target="adjustmentTaxRateInput"]')

      return this.previewInputInRange(
        amountInput,
        'integer',
        { minimum: 0, maximum: this.receiptAdjustmentAmountMaxValue }
      ) && this.previewInputInRange(taxRateInput, 'decimal', { minimum: 0, maximum: 100 })
    })

    if (!adjustmentsValid) return false

    return this.paymentRowTargets.every((row) => {
      if (this.previewRowExcluded(row, 'paymentDestroyField')) return true

      const amountInput = row.querySelector('[data-receipt-form-target="paymentAmountInput"]')
      return this.previewInputInRange(
        amountInput,
        'integer',
        { minimum: 0, maximum: this.receiptPaymentAmountMaxValue }
      )
    })
  }

  previewRowExcluded (row, destroyTarget) {
    if (row.style.display === 'none') return true

    const destroyField = row.querySelector(`[data-receipt-form-target="${destroyTarget}"]`)
    return String(destroyField?.value ?? '') === '1'
  }

  pricingSourceModeValid (mode, { count, reference, explicit }) {
    if (mode === 'reference_quantity_price') return reference()
    if (mode === 'explicit_line_total') return explicit()

    return count()
  }

  previewInputInRange (input, parser, range) {
    return this.previewValueInRange(this.previewInputValue(input, parser), range)
  }

  previewInputValue (input, parser) {
    const rawValue = String(input?.value ?? '').trim()
    if (rawValue === '') return null

    return parser === 'integer'
      ? this.parseIntegerInput(rawValue)
      : this.parseDecimalInput(rawValue)
  }

  previewValueInRange (value, { minimum, maximum, exclusiveMinimum = false }) {
    return previewValueInRange(value, { minimum, maximum, exclusiveMinimum })
  }

  renderUnavailablePreview () {
    this.lastFinalPaymentTotal = null
    const preservedLineTotalTargets = new Set(
      Array.from(this.itemRowTargets || [])
        .filter((row) => this.explicitLineTotalSourceMissingForRow(row))
        .flatMap((row) => (
          Array.from(row?.querySelectorAll?.('[data-receipt-form-target="lineTotalDisplay"]') || [])
        ))
    )
    this.previewAmountTargets().forEach((target) => {
      if (!preservedLineTotalTargets.has(target)) this.renderUnavailableAmount(target)
    })

    if (this.hasTaxRateSummaryTarget) {
      this.taxRateSummaryTarget.textContent = this.unsetLabelValue
    }

    this.paymentMismatchWarningTargets.forEach((warning) => warning.classList.add('hidden'))
    this.syncPaymentAmountButtonTargets.forEach((button) => button.classList.add('hidden'))
    this.syncPaymentSummaryLayout()
  }

  previewAmountTargets () {
    return [
      ...this.lineTotalDisplayTargets,
      ...(this.hasTotalAmountTarget ? [this.totalAmountTarget] : []),
      ...(this.hasSubtotalAmountTarget ? [this.subtotalAmountTarget] : []),
      ...(this.hasTaxAmountTarget ? [this.taxAmountTarget] : []),
      ...(this.hasPaymentAdjustmentAmountTarget ? [this.paymentAdjustmentAmountTarget] : []),
      ...(this.hasFinalPaymentAmountTarget ? [this.finalPaymentAmountTarget] : []),
      ...(this.hasPaymentAmountSumTarget ? [this.paymentAmountSumTarget] : []),
      ...(this.hasPaymentReconciliationFinalAmountTarget ? [this.paymentReconciliationFinalAmountTarget] : []),
      ...(this.hasPaymentDifferenceAmountTarget ? [this.paymentDifferenceAmountTarget] : [])
    ]
  }

  renderUnavailableAmount (target) {
    this.cancelAmountAnimation(target)
    target.textContent = this.unsetLabelValue
    target.title = this.unsetLabelValue
    target.amountDisplayValue = Number.NaN
    delete target.dataset.amountValue
  }

  animateAmount (target, nextValue) {
    const duration = 300
    const startValue = this.currentAmountValue(target)
    const endValue = Math.floor(nextValue)
    const requestedAt = performance.now()
    const renderImmediately = this.shouldRenderAmountImmediately(target, requestedAt)
    const animationToken = this.startAmountAnimation(target)

    const render = (value) => {
      const displayValue = Math.floor(value)
      target.textContent = `¥${this.formatNumber(displayValue)}`
      target.title = target.textContent.trim()
      this.syncAmountDisplayState(target, displayValue)
      this.syncPaymentSummaryLayout()
    }

    if (startValue === endValue || renderImmediately) {
      render(endValue)
      this.finishAmountAnimation(target, animationToken, endValue)
      return
    }

    const startedAt = requestedAt

    const tick = (currentTime) => {
      if (!this.isCurrentAmountAnimation(target, animationToken)) return

      const progress = Math.min((currentTime - startedAt) / duration, 1)
      const easedProgress = this.easeOutCubic(progress)
      const currentValue = startValue + (endValue - startValue) * easedProgress

      render(currentValue)

      if (progress < 1) {
        target.amountAnimationFrame = requestAnimationFrame(tick)
      } else {
        render(endValue)
        this.finishAmountAnimation(target, animationToken, endValue)
      }
    }

    target.amountAnimationFrame = requestAnimationFrame(tick)
  }

  currentAmountValue (target) {
    if (Number.isFinite(target.amountDisplayValue)) {
      return target.amountDisplayValue
    }

    const rawText = target.textContent || ''
    const textValue = parseInt(rawText.replace(/[^0-9-]/g, ''), 10)
    if (!Number.isNaN(textValue)) return textValue

    if (target.dataset.amountValue) {
      return parseInt(target.dataset.amountValue, 10) || 0
    }

    return 0
  }

  shouldRenderAmountImmediately (target, requestedAt) {
    const lastRequestedAt = target.amountLastRequestedAt
    target.amountLastRequestedAt = requestedAt

    return Number.isFinite(lastRequestedAt) &&
      requestedAt - lastRequestedAt < this.continuousAmountUpdateThreshold
  }

  startAmountAnimation (target) {
    this.cancelAmountAnimation(target)
    target.amountAnimationToken = (target.amountAnimationToken || 0) + 1
    return target.amountAnimationToken
  }

  cancelAmountAnimation (target) {
    if (target.amountAnimationFrame) {
      cancelAnimationFrame(target.amountAnimationFrame)
    }

    target.amountAnimationFrame = null
    target.amountAnimationToken = (target.amountAnimationToken || 0) + 1
  }

  isCurrentAmountAnimation (target, animationToken) {
    return target.amountAnimationToken === animationToken
  }

  finishAmountAnimation (target, animationToken, endValue) {
    if (!this.isCurrentAmountAnimation(target, animationToken)) return

    target.amountAnimationFrame = null
    this.syncAmountDisplayState(target, endValue)
  }

  syncAmountDisplayState (target, value) {
    const amountValue = Math.floor(value)
    target.amountDisplayValue = amountValue
    target.dataset.amountValue = String(amountValue)
  }

  amountAnimationTargets () {
    return [
      ...this.lineTotalDisplayTargets,
      ...(this.hasTotalAmountTarget ? [this.totalAmountTarget] : []),
      ...(this.hasSubtotalAmountTarget ? [this.subtotalAmountTarget] : []),
      ...(this.hasTaxAmountTarget ? [this.taxAmountTarget] : []),
      ...(this.hasPaymentAmountSumTarget ? [this.paymentAmountSumTarget] : []),
      ...(this.hasPaymentReconciliationFinalAmountTarget ? [this.paymentReconciliationFinalAmountTarget] : [])
    ]
  }

  easeOutCubic (progress) {
    return easeOutCubic(progress)
  }

  formatTaxRateSummary (taxRates) {
    return formatTaxRateSummary(taxRates, {
      unsetLabel: this.unsetLabelValue,
      multipleTaxRatesLabel: this.multipleTaxRatesLabelValue
    })
  }
}
