import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "input"]

  connect() {
    this.handleOutsideTap = this.handleOutsideTap.bind(this)
    this.close()
    document.addEventListener("pointerdown", this.handleOutsideTap)
  }

  disconnect() {
    document.removeEventListener("pointerdown", this.handleOutsideTap)
  }

  open() {
    if (!this.hasPanelTarget) return

    this.panelTarget.classList.remove("hidden")

    if (this.hasInputTarget) {
      requestAnimationFrame(() => this.inputTarget.focus())
    }
  }

  close() {
    if (!this.hasPanelTarget) return

    this.panelTarget.classList.add("hidden")
  }

  toggle() {
    if (!this.hasPanelTarget) return

    if (this.panelTarget.classList.contains("hidden")) {
      this.open()
    } else {
      this.close()
    }
  }

  handleOutsideTap(event) {
    if (!this.hasPanelTarget) return
    if (this.panelTarget.classList.contains("hidden")) return
    if (this.panelTarget.contains(event.target)) return
    if (event.target.closest("[data-action~='search#toggle']")) return

    this.close()
  }
}
