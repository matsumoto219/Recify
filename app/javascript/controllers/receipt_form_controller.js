import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "itemsContainer",
    "template",
    "itemRow",
    "destroyField",
    "quantityInput",
    "priceInput",
    "lineTotalDisplay",
    "lineTotalInput",
    "totalAmount"
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
    let total = 0

    this.itemRowTargets.forEach((row) => {
      // 削除済み（非表示）はスキップ
      if (row.style.display === "none") return

      const quantityInput = row.querySelector('[data-receipt-form-target="quantityInput"]')
      const priceInput = row.querySelector('[data-receipt-form-target="priceInput"]')
      const lineTotalDisplay = row.querySelector('[data-receipt-form-target="lineTotalDisplay"]')
      const lineTotalInput = row.querySelector('[data-receipt-form-target="lineTotalInput"]')

      const quantity = parseFloat(quantityInput?.value) || 0
      const price = parseFloat(priceInput?.value) || 0

      const lineTotal = quantity * price
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
      this.totalAmountTarget.textContent = `¥${this.formatNumber(total)}`
    }
  }

  formatNumber(num) {
    return Math.floor(num).toLocaleString()
  }
}
