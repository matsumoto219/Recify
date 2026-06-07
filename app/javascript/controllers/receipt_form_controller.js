import { Controller } from '@hotwired/stimulus'

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
    receiptTaxBasis: { type: String, default: 'internal' },
    subtotalLabel: { type: String, default: 'Subtotal' },
    unsetLabel: { type: String, default: 'Unset' },
    multipleTaxRatesLabel: { type: String, default: 'Multiple tax rates' },
    adjustmentPaymentKinds: { type: String, default: 'point_usage' },
    adjustmentSurchargeKinds: { type: String, default: 'service_charge,late_night_charge,delivery_fee,bag_fee,handling_fee' },
    adjustmentDiscountKinds: { type: String, default: 'receipt_discount,coupon,point_usage,return_refund' },
    adjustmentSurchargeLabel: { type: String, default: 'Surcharge' },
    adjustmentDiscountLabel: { type: String, default: 'Discount' },
    decimalQuantityUnits: { type: String, default: 'kg,g,mg,L,ml,cc' },
    integerQuantityStep: { type: String, default: '1' },
    decimalQuantityStep: { type: String, default: '0.001' }
  }

  connect () {
    this.lineTotalTooltipDelay = 500
    this.continuousAmountUpdateThreshold = 150
    this.handleBeforeCache = this.handleBeforeCache.bind(this)
    document.addEventListener('turbo:before-cache', this.handleBeforeCache)
    this.syncItemDetailsPanels()
    this.syncAdjustmentDetailsPanels()
    this.syncQuantityInputSteps()
    this.syncAdjustmentSigns()
  }

  disconnect () {
    document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
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

  removeAdjustment (event) {
    event.preventDefault()

    const row = this.adjustmentRowForAction(event.currentTarget)
    if (!row) return

    const skipConfirmation = event.currentTarget.dataset.receiptFormSkipDeleteConfirmation === 'true'
    delete event.currentTarget.dataset.receiptFormSkipDeleteConfirmation

    if (!skipConfirmation && this.deleteConfirmationEnabledValue && !window.confirm(this.deleteAdjustmentConfirmationMessageValue)) return

    const destroyField = row.querySelector('[data-receipt-form-target="adjustmentDestroyField"]')
    const rowContainer = this.adjustmentRowContainer(row)

    if (destroyField) {
      destroyField.value = '1'
      row.style.display = 'none'
      if (rowContainer !== row) rowContainer.style.display = 'none'
    } else {
      rowContainer.remove()
    }

    this.recalculate()
  }

  removePayment (event) {
    event.preventDefault()

    const row = this.paymentRowForAction(event.currentTarget)
    if (!row) return

    const skipConfirmation = event.currentTarget.dataset.receiptFormSkipDeleteConfirmation === 'true'
    delete event.currentTarget.dataset.receiptFormSkipDeleteConfirmation

    if (!skipConfirmation && this.deleteConfirmationEnabledValue && !window.confirm(this.deletePaymentConfirmationMessageValue)) return

    const destroyField = row.querySelector('[data-receipt-form-target="paymentDestroyField"]')
    const rowContainer = this.paymentRowContainer(row)

    if (destroyField) {
      destroyField.value = '1'
      row.style.display = 'none'
      if (rowContainer !== row) rowContainer.style.display = 'none'
    } else {
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

  preventIntegerQuantityDecimalInput (event) {
    if (event.isComposing) return
    if (event.inputType !== 'insertText') return
    if (!this.integerQuantityInput(event.target)) return
    if (!this.decimalSeparatorText(event.data)) return

    event.preventDefault()
  }

  sanitizeQuantityInput (event) {
    if (event.isComposing) return
    if (!this.integerQuantityInput(event.target)) return

    const sanitizedValue = this.integerQuantityText(event.target.value)
    if (event.target.value !== sanitizedValue) {
      event.target.value = sanitizedValue
    }
  }

  removeItem (event) {
    event.preventDefault()

    const row = this.itemRowForAction(event.currentTarget)
    if (!row) return

    const skipConfirmation = event.currentTarget.dataset.receiptFormSkipDeleteConfirmation === 'true'
    delete event.currentTarget.dataset.receiptFormSkipDeleteConfirmation

    if (!skipConfirmation && this.deleteConfirmationEnabledValue && !window.confirm(this.deleteConfirmationMessageValue)) return

    const destroyField = row.querySelector('[data-receipt-form-target="destroyField"]')
    const rowContainer = this.itemRowContainer(row)

    if (destroyField) {
      // 既存レコード → _destroy を有効にして非表示
      destroyField.value = '1'
      row.style.display = 'none'
      if (rowContainer !== row) rowContainer.style.display = 'none'
    } else {
      // 新規レコード → DOMから削除
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
    let subtotalSum = 0
    let taxSum = 0
    let total = 0
    let paymentAdjustmentTotal = 0
    const taxRates = new Set()
    const externalTaxGroups = new Map()
    const externalTax = this.usesExternalTax()

    this.itemRowTargets.forEach((row) => {
      // 削除済み（非表示）はスキップ
      if (row.style.display === 'none') return

      const quantityInput = row.querySelector('[data-receipt-form-target="quantityInput"]')
      const quantityUnitInput = row.querySelector('[data-receipt-form-target="quantityUnitInput"]')
      const priceInput = row.querySelector('[data-receipt-form-target="priceInput"]')
      const discountRateInput = row.querySelector('[data-receipt-form-target="discountRateInput"]')
      const taxRateInput = row.querySelector('[data-receipt-form-target="taxRateInput"]')
      const lineTotalDisplays = row.querySelectorAll('[data-receipt-form-target="lineTotalDisplay"]')
      const lineTotalInput = row.querySelector('[data-receipt-form-target="lineTotalInput"]')

      let quantity = this.clampNumber(this.parseDecimalInput(quantityInput?.value), 0, 9999)
      if (quantity <= 0) quantity = 1
      const price = this.clampNumber(this.parseIntegerInput(priceInput?.value), 0, 999999999)
      const discountRatePercent = this.parseDiscountRateInput(discountRateInput?.value)
      const taxRatePercent = this.clampNumber(parseFloat(taxRateInput?.value) || 0, 0, 100)
      const quantityUnit = quantityUnitInput?.value

      if (taxRatePercent > 0) {
        taxRates.add(taxRatePercent)
      }

      // 税込単価前提（浮動小数点誤差回避のため整数計算）
      const originalLineTotal = this.originalLineTotalFor({ quantity, price, quantityUnit, lineTotalInput })
      let lineTotal = this.lineTotalFor({ originalLineTotal, discountRatePercent, discountRateInput, lineTotalInput })
      let tax = 0
      let subtotal = lineTotal

      if (externalTax) {
        if (taxRatePercent > 0) {
          externalTaxGroups.set(taxRatePercent, (externalTaxGroups.get(taxRatePercent) || 0) + lineTotal)
        }
      } else {
        tax = taxRatePercent > 0
          ? this.applyTaxRounding((lineTotal * taxRatePercent) / (100 + taxRatePercent))
          : 0
        subtotal = lineTotal - tax
      }

      lineTotal = this.clampNumber(lineTotal, 0, 999999999)
      subtotal = this.clampNumber(subtotal, 0, 999999999)
      tax = this.clampNumber(tax, 0, 999999999)

      subtotalSum += subtotal
      taxSum += tax
      total += lineTotal

      // 表示更新（PCツールチップ / スマホ小計など、同一行内の複数表示に対応）
      lineTotalDisplays.forEach((lineTotalDisplay) => {
        const withLabel = Boolean(lineTotalDisplay.closest('[data-receipt-form-target="lineTotalTooltip"]'))
        this.animateLineTotal(lineTotalDisplay, lineTotal, { withLabel })
      })

      this.syncLineTotalState({ lineTotalInput, quantityUnit, originalLineTotal, lineTotal })
    })

    this.adjustmentRowTargets.forEach((row) => {
      if (row.style.display === 'none') return

      this.syncAdjustmentSignForRow(row)

      const amountInput = row.querySelector('[data-receipt-form-target="adjustmentAmountInput"]')
      const taxRateInput = row.querySelector('[data-receipt-form-target="adjustmentTaxRateInput"]')
      const effect = this.adjustmentEffectForRow(row)
      const sign = this.adjustmentSignForRow(row)
      const amount = this.clampNumber(this.parseIntegerInput(amountInput?.value), 0, 999999999)
      const taxRatePercent = this.clampNumber(parseFloat(taxRateInput?.value) || 0, 0, 100)
      if (amount <= 0) return

      if (taxRatePercent > 0 && effect !== 'payment_adjustment') {
        taxRates.add(taxRatePercent)
      }

      const signedAmount = sign === 'surcharge' ? amount : -amount
      if (effect === 'payment_adjustment') {
        paymentAdjustmentTotal += signedAmount
        return
      }

      let adjustmentTax = 0
      let adjustmentSubtotal = signedAmount

      if (externalTax) {
        if (taxRatePercent > 0) {
          externalTaxGroups.set(taxRatePercent, (externalTaxGroups.get(taxRatePercent) || 0) + signedAmount)
        }
      } else if (taxRatePercent > 0) {
        const signMultiplier = signedAmount < 0 ? -1 : 1
        adjustmentTax = signMultiplier * this.applyTaxRounding((Math.abs(signedAmount) * taxRatePercent) / (100 + taxRatePercent))
        adjustmentSubtotal = signedAmount - adjustmentTax
      }

      subtotalSum += adjustmentSubtotal
      taxSum += adjustmentTax
      total += signedAmount
    })

    if (externalTax) {
      taxSum = this.externalTaxTotal(externalTaxGroups)
      total = subtotalSum + taxSum
    }

    total = this.clampNumber(total, 0, 999999999)
    subtotalSum = this.clampNumber(subtotalSum, 0, 999999999)
    taxSum = this.clampNumber(taxSum, 0, 999999999)
    const finalPaymentTotal = this.clampNumber(total + paymentAdjustmentTotal, 0, 999999999)
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
  }

  paymentAmountSum () {
    return this.visiblePaymentRows().reduce((sum, row) => {
      const amountInput = row.querySelector('[data-receipt-form-target="paymentAmountInput"]')
      const amount = this.clampNumber(this.parseIntegerInput(amountInput?.value), 0, 999999999)

      return sum + amount
    }, 0)
  }

  visiblePaymentRows () {
    return this.paymentRowTargets.filter((row) => {
      if (row.style.display === 'none') return false

      const destroyField = row.querySelector('[data-receipt-form-target="paymentDestroyField"]')
      return String(destroyField?.value ?? '') !== '1'
    })
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

    const nextFirstAmount = this.parseIntegerInput(firstInput.value) + delta

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
    return ['floor', 'ceil', 'round'].includes(value) ? value : 'floor'
  }

  applyRounding (value, roundingMode) {
    switch (this.normalizeRoundingMode(roundingMode)) {
      case 'ceil':
        return Math.ceil(value)
      case 'round':
        return Math.round(value)
      default:
        return Math.floor(value)
    }
  }

  applyTaxRounding (value) {
    return this.applyRounding(value, this.roundingModeValue)
  }

  applyDiscountRounding (value) {
    return this.applyRounding(value, this.discountRoundingModeValue)
  }

  formatSignedAmount (value) {
    const amount = Math.floor(Math.abs(value))
    const sign = value < 0 ? '-' : '+'

    return `${sign}¥${this.formatNumber(amount)}`
  }

  formatPaymentDifference (value) {
    if (value === 0) return `¥${this.formatNumber(0)}`

    return this.formatSignedAmount(value)
  }

  usesExternalTax () {
    return this.receiptTaxBasisValue === 'external'
  }

  externalTaxTotal (taxGroups) {
    let taxTotal = 0

    taxGroups.forEach((groupLineTotal, taxRatePercent) => {
      taxTotal += this.applyTaxRounding((groupLineTotal * taxRatePercent) / 100)
    })

    return taxTotal
  }

  roundLineAmount (value) {
    return Math.round(value)
  }

  originalLineTotalFor ({ quantity, price, quantityUnit, lineTotalInput }) {
    if (this.recalculatesQuantityUnit(quantityUnit)) {
      return this.roundLineAmount(quantity * price)
    }

    return this.originalLineTotalInputValue(lineTotalInput)
  }

  discountedLineTotalFor (originalLineTotal, discountRatePercent) {
    if (discountRatePercent === null) return originalLineTotal

    const discountAmount = this.applyDiscountRounding((originalLineTotal * discountRatePercent) / 100)
    return Math.max(originalLineTotal - discountAmount, 0)
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
    const rawValue = String(value ?? '').trim()
    if (rawValue === '') return ''

    return String(this.parseDecimalInput(rawValue))
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
    }
  }

  recalculatesQuantityUnit (unit) {
    return this.countableQuantityUnits().includes(String(unit ?? '').trim())
  }

  countableQuantityUnits () {
    return ['個', '点', '本', '袋', '枚', '台', '箱', 'セット']
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
    return this.decimalQuantityUnitsValue
      .split(',')
      .map((unit) => unit.trim())
      .filter((unit) => unit !== '')
  }

  decimalSeparatorText (value) {
    return /[.,．，]/.test(String(value ?? ''))
  }

  hasDecimalSeparator (value) {
    return this.decimalSeparatorText(value)
  }

  decimalFractionIsZero (value) {
    const normalized = this.normalizeQuantityText(value)
    const decimalPart = normalized.split(/[.,]/)[1]

    return decimalPart === undefined || /^0*$/.test(decimalPart.replace(/[^0-9]/g, ''))
  }

  integerQuantityText (value) {
    const normalized = this.normalizeQuantityText(value)
    const integerPart = normalized.split(/[.,]/)[0]

    return integerPart
      .replace(/[^0-9-]/g, '')
      .replace(/(?!^)-/g, '')
  }

  normalizeQuantityText (value) {
    return String(value ?? '')
      .replace(/[０-９]/g, (s) => String.fromCharCode(s.charCodeAt(0) - 0xFEE0))
      .replace(/．/g, '.')
      .replace(/，/g, ',')
      .replace(/－/g, '-')
  }

  formatNumber (num) {
    return Math.floor(num).toLocaleString()
  }

  clampNumber (value, min, max) {
    if (Number.isNaN(value)) return min
    return Math.min(Math.max(value, min), max)
  }

  parseIntegerInput (value) {
    const normalized = String(value ?? '')
      .replace(/[０-９]/g, (s) => String.fromCharCode(s.charCodeAt(0) - 0xFEE0))
      .replace(/[^0-9-]/g, '')
      .replace(/(?!^)-/g, '')

    const parsedValue = Number.parseInt(normalized, 10)
    return Number.isNaN(parsedValue) ? 0 : parsedValue
  }

  parseDecimalInput (value) {
    let normalized = String(value ?? '').replace(/[０-９]/g, (s) =>
      String.fromCharCode(s.charCodeAt(0) - 0xFEE0)
    )

    normalized = normalized
      .replace(/．/g, '.')
      .replace(/－/g, '-')
      .replace(/，/g, ',')

    const commaCount = (normalized.match(/,/g) || []).length
    if (!normalized.includes('.') && commaCount === 1) {
      normalized = normalized.replace(',', '.')
    } else {
      normalized = normalized.replace(/,/g, '')
    }

    normalized = normalized
      .replace(/[^0-9.-]/g, '')
      .replace(/(?!^)-/g, '')

    const parts = normalized.split('.')
    if (parts.length > 2) {
      normalized = parts[0] + '.' + parts.slice(1).join('')
    }

    const parsedValue = Number.parseFloat(normalized)
    return Number.isNaN(parsedValue) ? 0 : parsedValue
  }

  parseDiscountRateInput (value) {
    const rawValue = String(value ?? '').trim()
    if (rawValue === '') return null

    return this.parseDecimalInput(rawValue)
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
    return 1 - Math.pow(1 - progress, 3)
  }

  formatTaxRateSummary (taxRates) {
    if (taxRates.size === 0) return this.unsetLabelValue
    if (taxRates.size > 1) return this.multipleTaxRatesLabelValue

    const [taxRate] = Array.from(taxRates)
    return `${this.formatTaxRate(taxRate)}%`
  }

  formatTaxRate (taxRate) {
    return Number.isInteger(taxRate) ? String(taxRate) : String(taxRate).replace(/\.0+$/, '')
  }
}
