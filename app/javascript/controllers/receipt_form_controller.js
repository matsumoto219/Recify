import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["itemsContainer", "template"]
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
}
