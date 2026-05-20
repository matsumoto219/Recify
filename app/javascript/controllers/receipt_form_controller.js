import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = [
    'itemsContainer',
    'template',
    'itemRow',
    'destroyField',
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
    'taxRateSummary'
  ]

  static values = {
    nextIndex: Number,
    roundingMode: { type: String, default: 'floor' },
    discountRoundingMode: { type: String, default: 'round' },
    confirmItemRemoval: { type: Boolean, default: true },
    confirmItemRemovalMessage: { type: String, default: 'Delete this item?' },
    receiptTaxBasis: { type: String, default: 'internal' },
    subtotalLabel: { type: String, default: 'Subtotal' },
    unsetLabel: { type: String, default: 'Unset' },
    multipleTaxRatesLabel: { type: String, default: 'Multiple tax rates' }
  }

  connect () {
    this.lineTotalTooltipDelay = 500
    this.continuousAmountUpdateThreshold = 150
  }

  disconnect () {
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
  }

  removeItem (event) {
    event.preventDefault()

    const row = event.currentTarget.closest('[data-receipt-form-target="itemRow"]')
    if (!row) return

    if (this.confirmItemRemovalValue && !window.confirm(this.confirmItemRemovalMessageValue)) return

    const destroyField = row.querySelector('[data-receipt-form-target="destroyField"]')

    if (destroyField) {
      // 既存レコード → _destroy を有効にして非表示
      destroyField.value = '1'
      row.style.display = 'none'
    } else {
      // 新規レコード → DOMから削除
      row.remove()
    }

    this.recalculate()
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

    const willOpen = panel.classList.contains('hidden')
    if (willOpen) this.hideLineTotalTooltipFor(row)

    panel.classList.toggle('hidden', !willOpen)
    row.classList.toggle('receipt-form-item-details-open', willOpen)

    toggles.forEach((toggle) => {
      toggle.setAttribute('aria-expanded', String(willOpen))
    })

    icons.forEach((icon) => {
      icon.classList.toggle('rotate-180', willOpen)
    })
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

    if (externalTax) {
      taxSum = this.externalTaxTotal(externalTaxGroups)
      total = subtotalSum + taxSum
    }

    total = this.clampNumber(total, 0, 999999999)
    subtotalSum = this.clampNumber(subtotalSum, 0, 999999999)
    taxSum = this.clampNumber(taxSum, 0, 999999999)

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
      return this.lineTotalInputValue(lineTotalInput)
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
      ...(this.hasTaxAmountTarget ? [this.taxAmountTarget] : [])
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
