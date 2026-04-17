import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="notice-surface"
export default class extends Controller {
  static values = {
    animation: String,
    autoDismiss: Boolean,
    autoDismissDelay: Number,
    maxVisible: Number
  }

  connect() {
    if (this.element.dataset.noticeInitialized === "true") return
    this.element.dataset.noticeInitialized = "true"

    if (this.maxVisibleValue > 0) {
      const selector = `[data-controller~="notice-surface"][data-notice-surface-max-visible-value="${this.maxVisibleValue}"]`
      const sameGroup = Array.from(document.querySelectorAll(selector))

      if (sameGroup.length > this.maxVisibleValue && sameGroup[0] === this.element) {
        this.element.remove()
        return
      }
    }

    requestAnimationFrame(() => {
      if (this.animationValue === "slide_right") {
        this.element.classList.remove("opacity-0", "translate-x-full")
      } else if (this.animationValue === "slide_down") {
        this.element.classList.remove("opacity-0", "-translate-y-4")
      } else {
        this.element.classList.remove("opacity-0")
      }
    })

    if (this.autoDismissValue) {
      const timeout = this.autoDismissDelayValue > 0 ? this.autoDismissDelayValue : 4000

      this.dismissTimeout = setTimeout(() => {
        if (!this.element.isConnected) return
        this.element.classList.add("opacity-0", "-translate-y-2")
        this.removeTimeout = setTimeout(() => this.element.remove(), 250)
      }, timeout)
    }
  }

  close() {
    if (!this.element.isConnected) return

    this.clearTimers()
    this.element.classList.add("opacity-0", "-translate-y-2")
    this.removeTimeout = setTimeout(() => this.element.remove(), 250)
  }

  disconnect() {
    this.clearTimers()
  }

  clearTimers() {
    if (this.dismissTimeout) {
      clearTimeout(this.dismissTimeout)
      this.dismissTimeout = null
    }

    if (this.removeTimeout) {
      clearTimeout(this.removeTimeout)
      this.removeTimeout = null
    }
  }
}
