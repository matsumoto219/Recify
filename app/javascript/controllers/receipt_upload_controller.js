import { Controller } from '@hotwired/stimulus'

const ALLOWED_RECEIPT_IMAGE_TYPES = [
  'image/jpeg',
  'image/png',
  'image/bmp',
  'image/tiff',
  'image/heif',
  'image/heic'
]

const ALLOWED_RECEIPT_IMAGE_EXTENSIONS = [
  '.jpg',
  '.jpeg',
  '.png',
  '.bmp',
  '.tif',
  '.tiff',
  '.heif',
  '.heic'
]

function isAllowedReceiptImageFile (file) {
  if (!file) return false

  const type = file.type?.toLowerCase()
  if (type) return ALLOWED_RECEIPT_IMAGE_TYPES.includes(type)

  const name = file.name?.toLowerCase() || ''
  return ALLOWED_RECEIPT_IMAGE_EXTENSIONS.some((extension) => name.endsWith(extension))
}

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
    emptyFileMessage: { type: String, default: 'No image selected yet.' },
    quotaExceededMessage: { type: String, default: 'Storage quota exceeded.' },
    storageUsedBytes: { type: Number, default: 0 },
    storageLimitBytes: { type: Number, default: 0 }
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

    if (this.exceedsStorageQuota(file)) {
      this.showFileError(this.quotaExceededMessageValue)
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

    if (this.exceedsStorageQuota(file)) {
      this.showFileError(this.quotaExceededMessageValue)
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
    this.cameraInputTarget.value = ''
    this.libraryInputTarget.value = ''
    this.fileNameTarget.textContent = message
    this.submitButtonTarget.disabled = true
  }

  isImageFile (file) {
    return isAllowedReceiptImageFile(file)
  }

  exceedsStorageQuota (file) {
    if (!file || this.storageLimitBytesValue <= 0) return false

    return this.storageUsedBytesValue + file.size > this.storageLimitBytesValue
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
