import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="receipt-image-card"
export default class extends Controller {
  static targets = ["content", "chevron", "toggleButton", "modal", "fileInput", "previewImage", "modalImage"]
  static values = { initiallyOpen: Boolean }

  connect() {
    this.isOpen = this.initiallyOpenValue
    this.objectUrl = null
    this.sync()

    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
  }

  disconnect() {
    this.unlockBodyScroll()
    this.revokeObjectUrl()
    document.removeEventListener("keydown", this.handleKeydown)
  }

  previewSelectedImage(event) {
    const file = event.target.files?.[0]
    if (!file || !file.type.startsWith("image/")) return

    this.revokeObjectUrl()
    this.objectUrl = URL.createObjectURL(file)

    if (this.hasPreviewImageTarget) {
      this.previewImageTarget.src = this.objectUrl
    }

    if (this.hasModalImageTarget) {
      this.modalImageTarget.src = this.objectUrl
    }
  }

  revokeObjectUrl() {
    if (this.objectUrl) {
      URL.revokeObjectURL(this.objectUrl)
      this.objectUrl = null
    }
  }

  toggle() {
    this.isOpen = !this.isOpen
    this.sync()
  }

  openModal() {
    if (!this.hasModalTarget || !this.hasModalImageTarget) return
    if (!this.modalTarget.classList.contains("hidden")) return

    this.modalTarget.classList.remove("hidden")
    this.modalTarget.setAttribute("aria-hidden", "false")
    this.lockBodyScroll()
    this.modalTarget.focus()
  }

  closeModal() {
    if (!this.hasModalTarget) return

    this.modalTarget.classList.add("hidden")
    this.modalTarget.setAttribute("aria-hidden", "true")
    this.unlockBodyScroll()
  }

  handleKeydown(e) {
    if (e.key !== "Escape") return
    if (!this.hasModalTarget || this.modalTarget.classList.contains("hidden")) return

    this.closeModal()
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
