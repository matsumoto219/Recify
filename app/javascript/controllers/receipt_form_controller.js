import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "itemsContainer",
    "template",
    "itemRow",
    "destroyField",
    "quantityInput",
    "priceInput",
    "taxRateInput",
    "lineTotalDisplay",
    "lineTotalInput",
    "totalAmount",
    "subtotalAmount",
    "taxAmount",
    "taxRateSummary"
  ]
  static values = { nextIndex: Number }

  addItem(event) {
    event.preventDefault()

    const template = this.templateTarget.innerHTML.trim()
    if (!template) return

    const index = this.nextIndexValue
    const html = template.replace(/NEW_RECORD/g, String(index))

    event.currentTarget.insertAdjacentHTML("beforebegin", html)
    this.nextIndexValue = index + 1
  }

  removeItem(event) {
    event.preventDefault()

    const row = event.currentTarget.closest('[data-receipt-form-target="itemRow"]')
    if (!row) return

    const destroyField = row.querySelector('[data-receipt-form-target="destroyField"]')

    if (destroyField) {
      // 既存レコード → _destroy を有効にして非表示
      destroyField.value = "1"
      row.style.display = "none"
    } else {
      // 新規レコード → DOMから削除
      row.remove()
    }

    this.recalculate()
  }

  recalculate() {
    let subtotalSum = 0
    let taxSum = 0
    let total = 0
    const taxRates = new Set()

    this.itemRowTargets.forEach((row) => {
      // 削除済み（非表示）はスキップ
      if (row.style.display === "none") return

      const quantityInput = row.querySelector('[data-receipt-form-target="quantityInput"]')
      const priceInput = row.querySelector('[data-receipt-form-target="priceInput"]')
      const taxRateInput = row.querySelector('[data-receipt-form-target="taxRateInput"]')
      const lineTotalDisplay = row.querySelector('[data-receipt-form-target="lineTotalDisplay"]')
      const lineTotalInput = row.querySelector('[data-receipt-form-target="lineTotalInput"]')

      const quantity = parseFloat(quantityInput?.value) || 0
      const price = parseFloat(priceInput?.value) || 0
      const taxRatePercent = parseFloat(taxRateInput?.value) || 0
      const taxRate = taxRatePercent / 100

      if (taxRatePercent > 0) {
        taxRates.add(taxRatePercent)
      }

      // 税込単価前提の計算
      const lineTotal = quantity * price
      const subtotal = taxRate > 0 ? lineTotal / (1 + taxRate) : lineTotal
      const tax = lineTotal - subtotal

      subtotalSum += subtotal
      taxSum += tax
      total += lineTotal

      // 表示更新
      if (lineTotalDisplay) {
        lineTotalDisplay.textContent = `¥${this.formatNumber(lineTotal)}`
      }

      // hidden更新
      if (lineTotalInput) {
        lineTotalInput.value = lineTotal
      }
    })

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

  formatNumber(num) {
    return Math.floor(num).toLocaleString()
  }

  animateAmount(target, nextValue) {
    const duration = 300
    const startValue = this.currentAmountValue(target)
    const endValue = Math.floor(nextValue)

    if (target.amountAnimationFrame) {
      cancelAnimationFrame(target.amountAnimationFrame)
    }

    if (startValue === endValue) {
      target.textContent = `¥${this.formatNumber(endValue)}`
      target.dataset.amountValue = String(endValue)
      return
    }

    const startedAt = performance.now()

    const tick = (currentTime) => {
      const progress = Math.min((currentTime - startedAt) / duration, 1)
      const easedProgress = this.easeOutCubic(progress)
      const currentValue = startValue + (endValue - startValue) * easedProgress

      target.textContent = `¥${this.formatNumber(currentValue)}`

      if (progress < 1) {
        target.amountAnimationFrame = requestAnimationFrame(tick)
      } else {
        target.textContent = `¥${this.formatNumber(endValue)}`
        target.dataset.amountValue = String(endValue)
        target.amountAnimationFrame = null
      }
    }

    target.amountAnimationFrame = requestAnimationFrame(tick)
  }

  currentAmountValue(target) {
    if (target.dataset.amountValue) {
      return parseInt(target.dataset.amountValue, 10) || 0
    }

    const rawText = target.textContent || ""
    return parseInt(rawText.replace(/[^0-9-]/g, ""), 10) || 0
  }

  easeOutCubic(progress) {
    return 1 - Math.pow(1 - progress, 3)
  }

  formatTaxRateSummary(taxRates) {
    if (taxRates.size === 0) return "未設定"
    if (taxRates.size > 1) return "複数税率"

    const [taxRate] = Array.from(taxRates)
    return `${this.formatTaxRate(taxRate)}%`
  }

  formatTaxRate(taxRate) {
    return Number.isInteger(taxRate) ? String(taxRate) : String(taxRate).replace(/\.0+$/, "")
  }
}
