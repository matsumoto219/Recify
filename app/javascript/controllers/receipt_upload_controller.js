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
    'previewControls',
    'previewPreviousButton',
    'previewNextButton',
    'previewCounter',
    'previewCurrentFileName',
    'dropzone',
    'dropOverlay'
  ]

  static values = {
    ocrAvailable: { type: Boolean, default: true },
    invalidImageMessage: { type: String, default: 'Please select an image file.' },
    emptyFileMessage: { type: String, default: 'No image selected yet.' },
    quotaExceededMessage: { type: String, default: 'Storage quota exceeded.' },
    maxFileCount: { type: Number, default: 5 },
    maxFileCountMessage: { type: String, default: 'Too many files selected.' },
    selectedFilesMessage: { type: String, default: '%{count} files selected: %{files}' },
    previewCounterMessage: { type: String, default: '%{current} / %{total}' },
    storageUsedBytes: { type: Number, default: 0 },
    storageLimitBytes: { type: Number, default: 0 }
  }

  connect () {
    this.selectedFiles = []
    this.previewIndex = 0
    this.previewObjectUrl = null
  }

  disconnect () {
    this.revokePreviewUrl()
  }

  openCamera () {
    if (!this.ocrAvailableValue) return

    this.cameraInputTarget.click()
  }

  openLibrary () {
    if (!this.ocrAvailableValue) return

    this.libraryInputTarget.click()
  }

  previewCamera () {
    if (this.cameraInputTarget.files.length === 0) return

    this.libraryInputTarget.value = ''
    this.previewFiles(this.cameraInputTarget.files, { single: true })
  }

  previewLibrary () {
    if (this.libraryInputTarget.files.length === 0) return

    this.cameraInputTarget.value = ''
    this.previewFiles(this.libraryInputTarget.files)
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

    const files = Array.from(event.dataTransfer?.files || [])
    if (files.length === 0) return
    if (!this.validateFiles(files)) return

    const dataTransfer = new DataTransfer()
    files.forEach((file) => dataTransfer.items.add(file))
    this.libraryInputTarget.files = dataTransfer.files
    this.cameraInputTarget.value = ''

    this.previewFiles(this.libraryInputTarget.files)
  }

  disableSubmit () {
    this.submitButtonTarget.disabled = true
  }

  previewFiles (fileList, { single = false } = {}) {
    const files = Array.from(fileList || [])
    const selectedFiles = single ? files.slice(0, 1) : files
    this.submitButtonTarget.disabled = selectedFiles.length === 0 || !this.ocrAvailableValue

    if (selectedFiles.length === 0) {
      this.clearPreview()
      return
    }

    if (!this.ocrAvailableValue) return
    if (!this.validateFiles(selectedFiles)) return

    this.showPreview(selectedFiles)
  }

  showPreview (files) {
    this.selectedFiles = files
    this.previewIndex = 0
    this.renderCurrentPreview()
    this.fileNameTarget.textContent = this.selectedFilesText(files)
  }

  previousPreview () {
    if (this.previewIndex <= 0) return

    this.previewIndex -= 1
    this.renderCurrentPreview()
  }

  nextPreview () {
    if (this.previewIndex >= this.selectedFiles.length - 1) return

    this.previewIndex += 1
    this.renderCurrentPreview()
  }

  renderCurrentPreview () {
    const previewFile = this.selectedFiles[this.previewIndex]

    if (!previewFile) {
      this.clearPreview()
      return
    }

    this.revokePreviewUrl()
    this.previewObjectUrl = URL.createObjectURL(previewFile)
    this.previewTarget.src = this.previewObjectUrl
    this.previewWrapperTarget.classList.remove('hidden')
    this.emptyStateTarget.classList.add('hidden')
    this.updatePreviewControls()
  }

  updatePreviewControls () {
    if (!this.hasPreviewControlsTarget) return

    if (this.selectedFiles.length <= 1) {
      this.hidePreviewControls()
      return
    }

    const currentFile = this.selectedFiles[this.previewIndex]
    this.previewControlsTarget.classList.remove('hidden')
    this.previewPreviousButtonTarget.disabled = this.previewIndex === 0
    this.previewNextButtonTarget.disabled = this.previewIndex === this.selectedFiles.length - 1
    this.previewCounterTarget.textContent = this.previewCounterText()
    this.previewCurrentFileNameTarget.textContent = currentFile.name
    this.previewCurrentFileNameTarget.title = currentFile.name
  }

  hidePreviewControls () {
    if (!this.hasPreviewControlsTarget) return

    this.previewControlsTarget.classList.add('hidden')
    this.previewPreviousButtonTarget.disabled = true
    this.previewNextButtonTarget.disabled = true
    this.previewCounterTarget.textContent = ''
    this.previewCurrentFileNameTarget.textContent = ''
    this.previewCurrentFileNameTarget.removeAttribute('title')
  }

  previewCounterText () {
    return this.previewCounterMessageValue
      .replace('%{current}', this.previewIndex + 1)
      .replace('%{total}', this.selectedFiles.length)
  }

  validateFiles (files) {
    if (files.length > this.maxFileCountValue) {
      this.showFileError(this.maxFileCountMessageValue)
      return false
    }

    if (files.some((file) => !this.isImageFile(file))) {
      this.showFileError(this.invalidImageMessageValue)
      return false
    }

    if (this.exceedsStorageQuota(files)) {
      this.showFileError(this.quotaExceededMessageValue)
      return false
    }

    return true
  }

  selectedFilesText (files) {
    if (files.length === 1) return files[0].name

    return this.selectedFilesMessageValue
      .replace('%{count}', files.length)
      .replace('%{files}', files.map((file) => file.name).join(', '))
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

  exceedsStorageQuota (files) {
    if (this.storageLimitBytesValue <= 0) return false

    const totalSize = Array.from(files || []).reduce((sum, file) => sum + file.size, 0)
    return this.storageUsedBytesValue + totalSize > this.storageLimitBytesValue
  }

  clearPreview () {
    this.revokePreviewUrl()
    this.selectedFiles = []
    this.previewIndex = 0
    this.previewTarget.src = ''
    this.previewWrapperTarget.classList.add('hidden')
    this.emptyStateTarget.classList.remove('hidden')
    this.fileNameTarget.textContent = this.emptyFileMessageValue
    this.hidePreviewControls()
  }

  revokePreviewUrl () {
    if (!this.previewObjectUrl) return

    URL.revokeObjectURL(this.previewObjectUrl)
    this.previewObjectUrl = null
  }
}
