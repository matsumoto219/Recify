import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["label", "value", "subtext"]

  connect() {
    this.isMonthly = true
  }

  toggle() {
    if (!this.hasLabelTarget || !this.hasValueTarget || !this.hasSubtextTarget) return

    if (this.isMonthly) {
      this.labelTarget.innerText = '合計金額'
      this.valueTarget.innerText = '¥' + this.valueTarget.dataset.overallTotal
      this.subtextTarget.innerText = this.subtextTarget.dataset.overallText
    } else {
      this.labelTarget.innerText = '今月の合計'
      this.valueTarget.innerText = '¥' + this.valueTarget.dataset.currentMonthTotal
      this.subtextTarget.innerText = this.subtextTarget.dataset.monthlyText
    }

    this.isMonthly = !this.isMonthly
  }
}
