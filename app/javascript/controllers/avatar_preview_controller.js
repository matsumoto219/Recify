import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="avatar-preview"
export default class extends Controller {
  static targets = [
    "input",
    "removeCheckbox",
    "image",
    "fallback",
    "error",
    "errorText"
  ]

  connect() {
    this.objectUrl = null
    this.persistedImageUrl = this.hasImageTarget ? this.imageTarget.dataset.persistedUrl || "" : ""
    this.defaultFallbackText = this.hasFallbackTarget ? this.fallbackTarget.dataset.defaultText || this.fallbackTarget.textContent.trim() : "U"
    this.hideError()
    this.refreshPreview()
  }

  disconnect() {
    this.revokeObjectUrl()
  }

  preview() {
    this.hideError()

    const file = this.inputTarget.files?.[0]
    if (!file) {
      this.refreshPreview()
      return
    }

    const validationError = this.validateFile(file)
    if (validationError) {
      this.inputTarget.value = ""
      this.showError(validationError)
      this.refreshPreview()
      return
    }

    if (this.hasRemoveCheckboxTarget) {
      this.removeCheckboxTarget.checked = false
    }

    this.revokeObjectUrl()
    this.objectUrl = URL.createObjectURL(file)
    this.showImage(this.objectUrl)
  }

  toggleRemove() {
    this.hideError()
    this.refreshPreview()
  }

  refreshPreview() {
    if (this.removeRequested()) {
      this.clearFileInput()
      this.showFallback()
      return
    }

    const file = this.inputTarget.files?.[0]
    if (file) {
      const validationError = this.validateFile(file)
      if (validationError) {
        this.clearFileInput()
        this.showError(validationError)
        this.showPersistedOrFallback()
        return
      }

      if (!this.objectUrl) {
        this.objectUrl = URL.createObjectURL(file)
      }
      this.showImage(this.objectUrl)
      return
    }

    this.showPersistedOrFallback()
  }

  validateFile(file) {
    const allowedTypes = ["image/png", "image/jpeg", "image/webp"]
    if (!allowedTypes.includes(file.type)) {
      return "PNG / JPG / WebP形式の画像を選択してください。"
    }

    const maxBytes = 5 * 1024 * 1024
    if (file.size > maxBytes) {
      return "画像サイズは5MB以下にしてください。"
    }

    return null
  }

  showPersistedOrFallback() {
    if (this.persistedImageUrl.length > 0) {
      this.showImage(this.persistedImageUrl)
    } else {
      this.showFallback()
    }
  }

  showImage(src) {
    if (!this.hasImageTarget) return

    this.imageTarget.src = src
    this.imageTarget.classList.remove("hidden")
    if (this.hasFallbackTarget) {
      this.fallbackTarget.classList.add("hidden")
    }
  }

  showFallback() {
    if (this.hasImageTarget) {
      this.imageTarget.src = ""
      this.imageTarget.classList.add("hidden")
    }
    if (this.hasFallbackTarget) {
      this.fallbackTarget.textContent = this.defaultFallbackText
      this.fallbackTarget.classList.remove("hidden")
    }
    this.revokeObjectUrl()
  }

  showError(message) {
    if (!this.hasErrorTarget || !this.hasErrorTextTarget) return

    this.errorTextTarget.textContent = message
    this.errorTarget.classList.remove("hidden")
  }

  hideError() {
    if (!this.hasErrorTarget || !this.hasErrorTextTarget) return

    this.errorTextTarget.textContent = ""
    this.errorTarget.classList.add("hidden")
  }

  removeRequested() {
    return this.hasRemoveCheckboxTarget && this.removeCheckboxTarget.checked
  }

  clearFileInput() {
    if (this.hasInputTarget) {
      this.inputTarget.value = ""
    }
    this.revokeObjectUrl()
  }

  revokeObjectUrl() {
    if (this.objectUrl) {
      URL.revokeObjectURL(this.objectUrl)
      this.objectUrl = null
    }
  }
}
