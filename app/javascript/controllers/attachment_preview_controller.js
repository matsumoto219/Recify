import { Controller } from '@hotwired/stimulus'

const ALLOWED_IMAGE_TYPES = [
  'image/jpeg',
  'image/png',
  'image/webp'
]

// Connects to data-controller="attachment-preview"
export default class extends Controller {
  static targets = [
    'input',
    'removeCheckbox',
    'image',
    'error',
    'errorText'
  ]

  static values = {
    invalidTypeMessage: { type: String, default: 'Please select a JPEG, PNG, or WebP image.' },
    fileTooLargeMessage: { type: String, default: 'Please select a smaller image.' },
    maxFileSizeBytes: { type: Number, default: 0 }
  }

  connect () {
    this.objectUrl = null
    this.persistedImageUrl = this.hasImageTarget ? this.imageTarget.dataset.persistedUrl || '' : ''
    this.hideError()
    this.refreshPreview()
  }

  disconnect () {
    if (this.objectUrl) this.showPersistedOrFallback()
  }

  preview () {
    this.hideError()

    const file = this.inputTarget.files?.[0]
    if (!file) {
      this.refreshPreview()
      return
    }

    const validationError = this.validateFile(file)
    if (validationError) {
      this.clearFileInput()
      this.showError(validationError)
      this.refreshPreview()
      return
    }

    if (this.hasRemoveCheckboxTarget) {
      this.removeCheckboxTarget.checked = false
    }

    const previousObjectUrl = this.objectUrl
    this.objectUrl = URL.createObjectURL(file)
    this.showImage(this.objectUrl)
    if (previousObjectUrl) URL.revokeObjectURL(previousObjectUrl)
  }

  toggleRemove () {
    this.hideError()
    this.refreshPreview()
  }

  refreshPreview () {
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

  validateFile (file) {
    if (!ALLOWED_IMAGE_TYPES.includes(file.type)) {
      return this.invalidTypeMessageValue
    }

    const maxBytes = this.maxFileSizeBytesValue
    if (maxBytes > 0 && file.size > maxBytes) {
      return this.fileTooLargeMessageValue
    }

    return null
  }

  showPersistedOrFallback () {
    if (this.persistedImageUrl.length > 0) {
      this.showImage(this.persistedImageUrl)
      this.revokeObjectUrl()
    } else {
      this.showFallback()
    }
  }

  showImage (src) {
    if (!this.hasImageTarget) return

    if (this.imageTarget.getAttribute('src') !== src) this.imageTarget.src = src
    this.dispatch('source-changed', { target: this.imageTarget })
  }

  showFallback () {
    if (this.hasImageTarget) {
      this.imageTarget.removeAttribute('src')
      this.dispatch('source-changed', { target: this.imageTarget })
    }
    this.revokeObjectUrl()
  }

  showError (message) {
    if (!this.hasErrorTarget || !this.hasErrorTextTarget) return

    this.errorTextTarget.textContent = message
    this.errorTarget.classList.remove('hidden')
  }

  hideError () {
    if (!this.hasErrorTarget || !this.hasErrorTextTarget) return

    this.errorTextTarget.textContent = ''
    this.errorTarget.classList.add('hidden')
  }

  removeRequested () {
    return this.hasRemoveCheckboxTarget && this.removeCheckboxTarget.checked
  }

  clearFileInput () {
    if (this.hasInputTarget) {
      this.inputTarget.value = ''
    }
    this.revokeObjectUrl()
  }

  revokeObjectUrl () {
    if (this.objectUrl) {
      URL.revokeObjectURL(this.objectUrl)
      this.objectUrl = null
    }
  }
}
