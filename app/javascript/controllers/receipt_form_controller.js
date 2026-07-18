import { Controller } from '@hotwired/stimulus'
import {
  decimalFractionIsZero,
  decimalSeparatorText,
  hasDecimalSeparator,
  integerQuantityText,
  normalizedOptionalDecimalInput,
  normalizeNumericInputText,
  normalizeQuantityText,
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
    'quantityInput',
    'quantityUnitInput',
    'priceInput',
    'discountRateInput',
    'taxRateInput',
    'lineTotalDisplay',
    'lineTotalTooltip',
    'lineTotalInput',
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
    receiptTaxBasis: { type: String, default: 'internal' },
    subtotalLabel: { type: String, default: 'Subtotal' },
    unsetLabel: { type: String, default: 'Unset' },
    multipleTaxRatesLabel: { type: String, default: 'Multiple tax rates' },
    adjustmentPaymentKinds: { type: String, default: 'point_usage' },
    adjustmentSurchargeKinds: { type: String, default: 'service_charge,late_night_charge,delivery_fee,bag_fee,handling_fee' },
    adjustmentDiscountKinds: { type: String, default: 'receipt_discount,coupon,point_usage,return_refund' },
    adjustmentSurchargeLabel: { type: String, default: 'Surcharge' },
    adjustmentDiscountLabel: { type: String, default: 'Discount' },
    countableQuantityUnits: { type: String, default: 'each,item,piece,bag,sheet,unit,box,set' },
    decimalQuantityUnits: { type: String, default: 'gram,kilogram,milligram,liter,milliliter,cubic_centimeter' },
    defaultQuantityUnit: { type: String, default: 'each' },
    integerQuantityStep: { type: String, default: '1' },
    decimalQuantityStep: { type: String, default: '0.001' },
    receiptTotalAmountMax: { type: Number, default: DEFAULT_AMOUNT_MAX },
    receiptItemPriceMax: { type: Number, default: DEFAULT_AMOUNT_MAX },
    receiptItemLineTotalMax: { type: Number, default: DEFAULT_AMOUNT_MAX },
    receiptTaxAmountMax: { type: Number, default: DEFAULT_AMOUNT_MAX },
    receiptAdjustmentAmountMax: { type: Number, default: DEFAULT_AMOUNT_MAX },
    receiptPaymentAmountMax: { type: Number, default: DEFAULT_AMOUNT_MAX },
    reviewItemTargetPrefix: String,
    reviewItemsTarget: String
  }

  connect () {
    this.lineTotalTooltipDelay = LINE_TOTAL_TOOLTIP_DELAY_MS
    this.continuousAmountUpdateThreshold = CONTINUOUS_AMOUNT_UPDATE_THRESHOLD_MS
    this.handleBeforeCache = this.handleBeforeCache.bind(this)
    this.handleReviewTargetClick = this.handleReviewTargetClick.bind(this)
    this.handleHashChange = this.handleHashChange.bind(this)
    document.addEventListener('turbo:before-cache', this.handleBeforeCache)
    this.element.addEventListener('click', this.handleReviewTargetClick)
    window.addEventListener('hashchange', this.handleHashChange)
    this.syncItemDetailsPanels()
    this.syncAdjustmentDetailsPanels()
    this.syncQuantityInputSteps()
    this.syncAdjustmentSigns()
    this.syncPaymentSummaryLayout()
    this.expandItemDetailsFromHash()
  }

  disconnect () {
    document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
    this.element.removeEventListener('click', this.handleReviewTargetClick)
    window.removeEventListener('hashchange', this.handleHashChange)
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

    this.syncQuantityInputStepForUnitSelect(unitSelect)
    this.clearFractionalQuantityForIntegerUnit(unitSelect)
    this.recalculate()
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
    if (!this.reviewItemTargetId(targetId)) return

    event.preventDefault()

    if (this.expandItemDetailsForReviewTarget(targetId, { scroll: true })) {
      this.pushReviewTargetHash(targetId)
      return
    }

    const fallbackTargetId = link.dataset.reviewReasonTarget || this.reviewItemsTargetValue
    this.pushReviewTargetHash(fallbackTargetId)
    this.scrollReviewTargetFallback(fallbackTargetId)
  }

  handleHashChange () {
    this.expandItemDetailsFromHash({ scroll: true })
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

  pushReviewTargetHash (targetId) {
    if (!targetId || typeof window.history?.pushState !== 'function') return

    const hash = reviewTargetHash(targetId)
    if (window.location.hash === hash) return

    window.history.pushState(null, '', hash)
  }

  scrollReviewTargetFallback (targetId = this.reviewItemsTargetValue) {
    const fallback = document.getElementById(targetId) || document.getElementById(this.reviewItemsTargetValue)
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
    this.syncItemDetailsPanels()
    this.syncAdjustmentDetailsPanels()
    this.syncAdjustmentSigns()
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

  recalculate () {
    if (!this.previewNumericInputsValid()) {
      this.renderUnavailablePreview()
      return
    }

    let subtotalSum = 0
    let taxSum = 0
    let total = 0
    let paymentAdjustmentTotal = 0
    const taxRates = new Set()
    const taxGroups = new Map()
    const externalTax = this.usesExternalTax()

    this.itemRowTargets.forEach((row) => {
      if (this.previewRowExcluded(row, 'destroyField')) return

      const quantityInput = row.querySelector('[data-receipt-form-target="quantityInput"]')
      const quantityUnitInput = row.querySelector('[data-receipt-form-target="quantityUnitInput"]')
      const priceInput = row.querySelector('[data-receipt-form-target="priceInput"]')
      const discountRateInput = row.querySelector('[data-receipt-form-target="discountRateInput"]')
      const taxRateInput = row.querySelector('[data-receipt-form-target="taxRateInput"]')
      const lineTotalDisplays = row.querySelectorAll('[data-receipt-form-target="lineTotalDisplay"]')
      const lineTotalInput = row.querySelector('[data-receipt-form-target="lineTotalInput"]')

      let quantity = this.clampNumber(this.parseDecimalInput(quantityInput?.value), 0, 9999)
      if (quantity <= 0) quantity = 1
      const price = this.clampNumber(this.parseIntegerInput(priceInput?.value), 0, this.receiptItemPriceMaxValue)
      const discountRatePercent = this.parseDiscountRateInput(discountRateInput?.value)
      const taxRatePercent = this.clampNumber(this.parseDecimalInput(taxRateInput?.value), 0, 100)
      const quantityUnit = quantityUnitInput?.value

      if (taxRatePercent > 0) {
        taxRates.add(taxRatePercent)
      }

      // 税込単価前提（浮動小数点誤差回避のため整数計算）
      const originalLineTotal = this.originalLineTotalFor({ quantity, price, quantityUnit, lineTotalInput })
      let lineTotal = this.lineTotalFor({ originalLineTotal, discountRatePercent, discountRateInput, lineTotalInput })
      lineTotal = this.clampNumber(lineTotal, 0, this.receiptItemLineTotalMaxValue)
      if (taxRatePercent > 0) {
        taxGroups.set(taxRatePercent, (taxGroups.get(taxRatePercent) || 0) + lineTotal)
      }

      subtotalSum += lineTotal
      total += lineTotal

      // 表示更新（PCツールチップ / スマホ小計など、同一行内の複数表示に対応）
      lineTotalDisplays.forEach((lineTotalDisplay) => {
        const withLabel = Boolean(lineTotalDisplay.closest('[data-receipt-form-target="lineTotalTooltip"]'))
        this.animateLineTotal(lineTotalDisplay, lineTotal, { withLabel })
      })

      this.syncLineTotalState({ lineTotalInput, quantityUnit, originalLineTotal, lineTotal })
    })

    this.adjustmentRowTargets.forEach((row) => {
      if (this.previewRowExcluded(row, 'adjustmentDestroyField')) return

      this.syncAdjustmentSignForRow(row)

      const amountInput = row.querySelector('[data-receipt-form-target="adjustmentAmountInput"]')
      const taxRateInput = row.querySelector('[data-receipt-form-target="adjustmentTaxRateInput"]')
      const effect = this.adjustmentEffectForRow(row)
      const sign = this.adjustmentSignForRow(row)
      const amount = this.clampNumber(this.parseIntegerInput(amountInput?.value), 0, this.receiptAdjustmentAmountMaxValue)
      const taxRatePercent = this.clampNumber(this.parseDecimalInput(taxRateInput?.value), 0, 100)
      if (amount <= 0) return

      if (taxRatePercent > 0 && effect !== 'payment_adjustment') {
        taxRates.add(taxRatePercent)
      }

      const signedAmount = sign === 'surcharge' ? amount : -amount
      if (effect === 'payment_adjustment') {
        paymentAdjustmentTotal += signedAmount
        return
      }

      if (taxRatePercent > 0) {
        taxGroups.set(taxRatePercent, (taxGroups.get(taxRatePercent) || 0) + signedAmount)
      }

      subtotalSum += signedAmount
      total += signedAmount
    })

    if (externalTax) {
      taxSum = this.externalTaxTotal(taxGroups)
      total = subtotalSum + taxSum
    } else {
      taxSum = this.internalTaxTotal(taxGroups)
      subtotalSum = total - taxSum
    }

    total = this.clampNumber(total, 0, this.receiptTotalAmountMaxValue)
    subtotalSum = this.clampNumber(subtotalSum, 0, this.receiptTotalAmountMaxValue)
    taxSum = this.clampNumber(taxSum, 0, this.receiptTaxAmountMaxValue)
    const finalPaymentTotal = this.clampNumber(total + paymentAdjustmentTotal, 0, this.receiptTotalAmountMaxValue)
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
      this.taxRateSummaryTarget.textContent = this.formatTaxRateSummary(taxRates)
    }

    this.syncPaymentAdjustmentSummary(paymentAdjustmentTotal, finalPaymentTotal)
    this.syncPaymentReconciliationSummary(this.paymentAmountSum(), finalPaymentTotal)
  }

  syncAdjustmentSigns () {
    this.adjustmentRowTargets.forEach((row) => this.syncAdjustmentSignForRow(row))
  }

  syncAdjustmentEffectForRow (row) {
    if (!row) return

    const kindInput = row.querySelector('[data-receipt-form-target="adjustmentKindInput"]')
    // 新規行やkind変更時だけJS側でeffectを推定する。既存行の初期effectはサーバー側分類を正とする。
    row.dataset.receiptFormAdjustmentEffect = this.adjustmentEffectForKind(kindInput?.value)
  }

  adjustmentEffectForRow (row) {
    const effect = String(row?.dataset.receiptFormAdjustmentEffect ?? '').trim()
    // 初期data属性のeffectを優先し、kind判定は新規行/フォールバック用に限定する。
    if (this.validAdjustmentEffect(effect)) return effect

    const kindInput = row?.querySelector('[data-receipt-form-target="adjustmentKindInput"]')
    return this.adjustmentEffectForKind(kindInput?.value)
  }

  adjustmentEffectForKind (kind) {
    const normalizedKind = String(kind ?? '').trim()
    if (this.adjustmentPaymentKindList().includes(normalizedKind)) return 'payment_adjustment'

    return 'purchase_adjustment'
  }

  validAdjustmentEffect (effect) {
    return ['purchase_adjustment', 'payment_adjustment', 'unknown_adjustment'].includes(effect)
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
    this.syncPaymentAmountButtonTargets.forEach((button) => button.classList.toggle('hidden', !mismatch))
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

  originalLineTotalFor ({ quantity, price, quantityUnit, lineTotalInput }) {
    if (this.recalculatesQuantityUnit(quantityUnit)) {
      return this.roundLineAmount(quantity * price)
    }

    return this.originalLineTotalInputValue(lineTotalInput)
  }

  discountedLineTotalFor (originalLineTotal, discountRatePercent) {
    return discountedLineTotal(originalLineTotal, discountRatePercent, this.discountRoundingModeValue)
  }

  lineTotalFor ({ originalLineTotal, discountRatePercent, discountRateInput, lineTotalInput }) {
    if (this.shouldPreserveExistingLineTotal({ originalLineTotal, discountRateInput, lineTotalInput })) {
      return this.preservedLineTotalInputValue(lineTotalInput)
    }

    return this.discountedLineTotalFor(originalLineTotal, discountRatePercent)
  }

  shouldPreserveExistingLineTotal ({ originalLineTotal, discountRateInput, lineTotalInput }) {
    if (!lineTotalInput) return false
    if (this.discountRateWasEdited(discountRateInput)) return false

    const persistedOriginalLineTotal = this.originalLineTotalInputValue(lineTotalInput)
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

  originalLineTotalInputValue (lineTotalInput) {
    return this.parseIntegerInput(lineTotalInput?.dataset.originalLineTotal || lineTotalInput?.value)
  }

  syncLineTotalState ({ lineTotalInput, quantityUnit, originalLineTotal, lineTotal }) {
    if (!lineTotalInput) return

    lineTotalInput.value = lineTotal

    if (this.recalculatesQuantityUnit(quantityUnit)) {
      lineTotalInput.dataset.originalLineTotal = String(originalLineTotal)
      lineTotalInput.dataset.originalSavedLineTotal = String(lineTotal)
    }
  }

  recalculatesQuantityUnit (unit) {
    return this.countableQuantityUnits().includes(String(unit ?? '').trim())
  }

  countableQuantityUnits () {
    return this.quantityUnitList(this.countableQuantityUnitsValue)
  }

  syncQuantityInputSteps () {
    this.quantityUnitInputTargets.forEach((unitSelect) => {
      this.syncQuantityInputStepForUnitSelect(unitSelect)
    })
  }

  syncQuantityInputStepForUnitSelect (unitSelect) {
    const row = unitSelect.closest('[data-receipt-form-target="itemRow"]')
    if (!row) return

    const quantityInput = row.querySelector('[data-receipt-form-target="quantityInput"]')
    if (!quantityInput) return

    const decimalAllowed = this.decimalQuantityUnit(unitSelect.value)
    quantityInput.step = decimalAllowed ? this.decimalQuantityStepValue : this.integerQuantityStepValue
    quantityInput.inputMode = decimalAllowed ? 'decimal' : 'numeric'
  }

  clearFractionalQuantityForIntegerUnit (unitSelect) {
    if (this.decimalQuantityUnit(unitSelect.value)) return

    const quantityInput = this.quantityInputForUnitSelect(unitSelect)
    if (!quantityInput) return

    const quantityText = String(quantityInput.value ?? '')
    if (!this.hasDecimalSeparator(quantityText)) return

    if (this.decimalFractionIsZero(quantityText)) {
      quantityInput.value = this.integerQuantityText(quantityText)
    } else {
      quantityInput.value = ''
    }
  }

  quantityInputForUnitSelect (unitSelect) {
    const row = unitSelect.closest('[data-receipt-form-target="itemRow"]')
    if (!row) return null

    return row.querySelector('[data-receipt-form-target="quantityInput"]')
  }

  quantityUnitSelectForInput (input) {
    const row = input.closest('[data-receipt-form-target="itemRow"]')
    if (!row) return null

    return row.querySelector('[data-receipt-form-target="quantityUnitInput"]')
  }

  integerQuantityInput (input) {
    const unitSelect = this.quantityUnitSelectForInput(input)
    return !this.decimalQuantityUnit(unitSelect?.value)
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

  decimalSeparatorText (value) {
    return decimalSeparatorText(value)
  }

  hasDecimalSeparator (value) {
    return hasDecimalSeparator(value)
  }

  decimalFractionIsZero (value) {
    return decimalFractionIsZero(value)
  }

  integerQuantityText (value) {
    return integerQuantityText(value)
  }

  normalizeQuantityText (value) {
    return normalizeQuantityText(value)
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
      const quantity = this.previewInputValue(quantityInput, 'decimal')

      return quantity !== null &&
        this.previewValueInRange(quantity, { minimum: 0, maximum: 9999.999, exclusiveMinimum: true }) &&
        (this.decimalQuantityUnit(quantityUnitInput?.value) || !Number.isFinite(quantity) || Number.isInteger(quantity)) &&
        this.previewInputInRange(priceInput, 'integer', { minimum: 0, maximum: this.receiptItemPriceMaxValue }) &&
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
    this.previewAmountTargets().forEach((target) => this.renderUnavailableAmount(target))

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
