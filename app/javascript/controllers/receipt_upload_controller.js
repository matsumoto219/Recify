import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = [
    'cameraInput',
    'libraryInput',
    'submitButton',
    'fileName',
    'emptyState',
    'previewWrapper',
    'preview',
    'dropzone',
    'dropOverlay'
  ]

  static values = {
    ocrAvailable: { type: Boolean, default: true },
    invalidImageMessage: { type: String, default: 'Please select an image file.' },
    emptyFileMessage: { type: String, default: 'No image selected yet.' }
  }

  connect () {
    this.selectedObjectUrl = null
  }

  disconnect () {
    this.revokePreviewUrl()
  }

  openCamera () {
    if (!this.ocrAvailableValue) return

    this.libraryInputTarget.value = ''
    this.cameraInputTarget.click()
  }

  openLibrary () {
    if (!this.ocrAvailableValue) return

    this.cameraInputTarget.value = ''
    this.libraryInputTarget.click()
  }

  previewCamera () {
    this.previewFile(this.cameraInputTarget.files?.[0])
  }

  previewLibrary () {
    this.previewFile(this.libraryInputTarget.files?.[0])
  }

  handleDragEnter (event) {
    event.preventDefault()
    if (!this.ocrAvailableValue) return

    this.showDropOverlay()
  }

  handleDragOver (event) {
    event.preventDefault()
    if (!this.ocrAvailableValue) return

    event.dataTransfer.dropEffect = 'copy'
    this.showDropOverlay()
  }

  handleDragLeave (event) {
    event.preventDefault()

    if (this.hasDropzoneTarget && this.dropzoneTarget.contains(event.relatedTarget)) return

    this.hideDropOverlay()
  }

  handleDrop (event) {
    event.preventDefault()
    this.hideDropOverlay()
    if (!this.ocrAvailableValue) return

    const file = event.dataTransfer?.files?.[0]
    if (!file) return

    if (!this.isImageFile(file)) {
      this.showFileError(this.invalidImageMessageValue)
      return
    }

    const dataTransfer = new DataTransfer()
    dataTransfer.items.add(file)
    this.libraryInputTarget.files = dataTransfer.files
    this.cameraInputTarget.value = ''

    this.previewFile(file)
  }

  disableSubmit () {
    this.submitButtonTarget.disabled = true
  }

  previewFile (file) {
    this.submitButtonTarget.disabled = !file || !this.ocrAvailableValue

    if (!file) {
      this.clearPreview()
      return
    }

    if (!this.ocrAvailableValue) return

    if (!this.isImageFile(file)) {
      this.showFileError(this.invalidImageMessageValue)
      return
    }

    this.revokePreviewUrl()
    this.selectedObjectUrl = URL.createObjectURL(file)
    this.previewTarget.src = this.selectedObjectUrl
    this.previewWrapperTarget.classList.remove('hidden')
    this.emptyStateTarget.classList.add('hidden')
    this.fileNameTarget.textContent = file.name
  }

  showDropOverlay () {
    if (!this.hasDropOverlayTarget) return

    this.dropOverlayTarget.classList.remove('hidden')
  }

  hideDropOverlay () {
    if (!this.hasDropOverlayTarget) return

    this.dropOverlayTarget.classList.add('hidden')
  }

  showFileError (message) {
    this.clearPreview()
    this.fileNameTarget.textContent = message
    this.submitButtonTarget.disabled = true
  }

  isImageFile (file) {
    return file.type.startsWith('image/')
  }

  clearPreview () {
    this.revokePreviewUrl()
    this.previewTarget.src = ''
    this.previewWrapperTarget.classList.add('hidden')
    this.emptyStateTarget.classList.remove('hidden')
    this.fileNameTarget.textContent = this.emptyFileMessageValue
  }

  revokePreviewUrl () {
    if (!this.selectedObjectUrl) return

    URL.revokeObjectURL(this.selectedObjectUrl)
    this.selectedObjectUrl = null
  }
}
