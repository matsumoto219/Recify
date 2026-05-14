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
    'taxRateInput',
    'lineTotalDisplay',
    'lineTotalTooltip',
    'lineTotalInput',
    'totalAmount',
    'subtotalAmount',
    'taxAmount',
    'taxRateSummary'
  ]

  static values = {
    nextIndex: Number,
    roundingMode: { type: String, default: 'floor' }
  }

  connect () {
    this.lineTotalTooltipDelay = 500
  }

  disconnect () {
    this.itemRowTargets.forEach((row) => this.clearLineTotalTooltipTimer(row))
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

  scheduleLineTotalTooltip (event) {
    // lg未満は表示しない
    if (window.innerWidth < 1024) return

    const row = event.currentTarget
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

    this.itemRowTargets.forEach((row) => {
      // 削除済み（非表示）はスキップ
      if (row.style.display === 'none') return

      const quantityInput = row.querySelector('[data-receipt-form-target="quantityInput"]')
      const quantityUnitInput = row.querySelector('[data-receipt-form-target="quantityUnitInput"]')
      const priceInput = row.querySelector('[data-receipt-form-target="priceInput"]')
      const taxRateInput = row.querySelector('[data-receipt-form-target="taxRateInput"]')
      const lineTotalDisplays = row.querySelectorAll('[data-receipt-form-target="lineTotalDisplay"]')
      const lineTotalInput = row.querySelector('[data-receipt-form-target="lineTotalInput"]')

      let quantity = this.clampNumber(this.parseDecimalInput(quantityInput?.value), 0, 9999)
      if (quantity <= 0) quantity = 1
      const price = this.clampNumber(this.parseIntegerInput(priceInput?.value), 0, 999999999)
      const taxRatePercent = this.clampNumber(parseFloat(taxRateInput?.value) || 0, 0, 100)
      const quantityUnit = quantityUnitInput?.value

      if (taxRatePercent > 0) {
        taxRates.add(taxRatePercent)
      }

      // 税込単価前提（浮動小数点誤差回避のため整数計算）
      let lineTotal = this.lineTotalFor({ quantity, price, quantityUnit, lineTotalInput })
      let tax = taxRatePercent > 0
        ? this.applyRounding((lineTotal * taxRatePercent) / (100 + taxRatePercent))
        : 0
      let subtotal = lineTotal - tax

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

      // hidden更新
      if (lineTotalInput) {
        lineTotalInput.value = lineTotal
      }
    })

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

    if (target.amountAnimationFrame) {
      cancelAnimationFrame(target.amountAnimationFrame)
    }

    const render = (value) => {
      const amountText = `¥${this.formatNumber(value)}`
      const text = withLabel ? `小計 ${amountText}` : amountText

      target.textContent = text
      target.title = text
    }

    if (startValue === endValue) {
      render(endValue)
      target.dataset.amountValue = String(endValue)
      return
    }

    const startedAt = performance.now()

    const tick = (currentTime) => {
      const progress = Math.min((currentTime - startedAt) / duration, 1)
      const easedProgress = this.easeOutCubic(progress)
      const currentValue = startValue + (endValue - startValue) * easedProgress

      render(currentValue)

      if (progress < 1) {
        target.amountAnimationFrame = requestAnimationFrame(tick)
      } else {
        render(endValue)
        target.dataset.amountValue = String(endValue)
        target.amountAnimationFrame = null
      }
    }

    target.amountAnimationFrame = requestAnimationFrame(tick)
  }

  normalizeRoundingMode (value) {
    return ['floor', 'ceil', 'round'].includes(value) ? value : 'floor'
  }

  applyRounding (value) {
    switch (this.normalizeRoundingMode(this.roundingModeValue)) {
      case 'ceil':
        return Math.ceil(value)
      case 'round':
        return Math.round(value)
      default:
        return Math.floor(value)
    }
  }

  roundLineAmount (value) {
    return Math.round(value)
  }

  lineTotalFor ({ quantity, price, quantityUnit, lineTotalInput }) {
    if (this.recalculatesQuantityUnit(quantityUnit)) {
      return this.roundLineAmount(quantity * price)
    }

    return this.parseIntegerInput(lineTotalInput?.value)
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

  animateAmount (target, nextValue) {
    const duration = 300
    const startValue = this.currentAmountValue(target)
    const endValue = Math.floor(nextValue)

    if (target.amountAnimationFrame) {
      cancelAnimationFrame(target.amountAnimationFrame)
    }

    if (startValue === endValue) {
      target.textContent = `¥${this.formatNumber(endValue)}`
      target.title = target.textContent.trim()
      target.dataset.amountValue = String(endValue)
      return
    }

    const startedAt = performance.now()

    const tick = (currentTime) => {
      const progress = Math.min((currentTime - startedAt) / duration, 1)
      const easedProgress = this.easeOutCubic(progress)
      const currentValue = startValue + (endValue - startValue) * easedProgress

      target.textContent = `¥${this.formatNumber(currentValue)}`
      target.title = target.textContent.trim()

      if (progress < 1) {
        target.amountAnimationFrame = requestAnimationFrame(tick)
      } else {
        target.textContent = `¥${this.formatNumber(endValue)}`
        target.title = target.textContent.trim()
        target.dataset.amountValue = String(endValue)
        target.amountAnimationFrame = null
      }
    }

    target.amountAnimationFrame = requestAnimationFrame(tick)
  }

  currentAmountValue (target) {
    if (target.dataset.amountValue) {
      return parseInt(target.dataset.amountValue, 10) || 0
    }

    const rawText = target.textContent || ''
    return parseInt(rawText.replace(/[^0-9-]/g, ''), 10) || 0
  }

  easeOutCubic (progress) {
    return 1 - Math.pow(1 - progress, 3)
  }

  formatTaxRateSummary (taxRates) {
    if (taxRates.size === 0) return '未設定'
    if (taxRates.size > 1) return '複数税率'

    const [taxRate] = Array.from(taxRates)
    return `${this.formatTaxRate(taxRate)}%`
  }

  formatTaxRate (taxRate) {
    return Number.isInteger(taxRate) ? String(taxRate) : String(taxRate).replace(/\.0+$/, '')
  }
}
