import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="receipt-image-card"
export default class extends Controller {
  static targets = ["content", "chevron", "toggleButton", "modal"]

  connect() {
    this.isOpen = false
    this.sync()

    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
  }

  disconnect() {
    this.unlockBodyScroll()
    document.removeEventListener("keydown", this.handleKeydown)
  }

  toggle() {
    this.isOpen = !this.isOpen
    this.sync()
  }

  openModal() {
    if (!this.hasModalTarget) return

    this.modalTarget.classList.remove("hidden")
    this.modalTarget.setAttribute("aria-hidden", "false")
    this.lockBodyScroll()
  }

  closeModal() {
    if (!this.hasModalTarget) return

    this.modalTarget.classList.add("hidden")
    this.modalTarget.setAttribute("aria-hidden", "true")
    this.unlockBodyScroll()
  }

  handleKeydown(e) {
    if (e.key === "Escape") {
      this.closeModal()
    }
  }

  stopPropagation(e) {
    e.stopPropagation()
  }

  sync() {
    if (this.hasContentTarget) {
      this.contentTarget.classList.toggle("hidden", !this.isOpen)
    }

    if (this.hasChevronTarget) {
      this.chevronTarget.classList.toggle("rotate-180", this.isOpen)
    }

    if (this.hasToggleButtonTarget) {
      this.toggleButtonTarget.setAttribute("aria-expanded", String(this.isOpen))
    }
  }

  lockBodyScroll() {
    document.body.classList.add("overflow-hidden")
  }

  unlockBodyScroll() {
    document.body.classList.remove("overflow-hidden")
  }
}
