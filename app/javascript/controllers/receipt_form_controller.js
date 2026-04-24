import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["itemsContainer", "template", "itemRow", "destroyField"]
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
  }
}
