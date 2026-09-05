import { Controller } from '@hotwired/stimulus'
import { CameraCapture, supportsInlineCamera } from 'receipts/camera_capture'

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

function cameraGuideBounds ({ videoWidth, videoHeight, video, frame, panel, inset }) {
  if (![videoWidth, videoHeight].every((value) => Number.isFinite(value) && value > 0)) return null
  if (!Number.isFinite(inset) || inset < 0) return null
  if (![video, frame, panel].every((rect) => rect &&
    ['left', 'top', 'width', 'height'].every((key) => Number.isFinite(rect[key])) && rect.width > 0 && rect.height > 0)) return null

  const scale = Math.min(video.width / videoWidth, video.height / videoHeight)
  const width = videoWidth * scale
  const height = videoHeight * scale
  const paintedLeft = video.left + (video.width - width) / 2
  const paintedTop = video.top + (video.height - height) / 2
  const left = Math.max(paintedLeft, frame.left, panel.left) + inset
  const top = Math.max(paintedTop, frame.top, panel.top) + inset
  const right = Math.min(paintedLeft + width, frame.left + frame.width, panel.left + panel.width) - inset
  const bottom = Math.min(paintedTop + height, frame.top + frame.height, panel.top + panel.height) - inset
  if (![left, top, right, bottom].every(Number.isFinite) || right <= left || bottom <= top) return null

  return { left: left - frame.left, top: top - frame.top, width: right - left, height: bottom - top }
}

export default class extends Controller {
  static targets = [
    'cameraInput',
    'cameraButton',
    'cameraPanel',
    'cameraVideo',
    'cameraLive',
    'cameraStatus',
    'cameraStatusTitle',
    'cameraStatusHelp',
    'cameraRetry',
    'cameraCancel',
    'cameraRotate',
    'cameraCaptureButton',
    'cameraDeviceField',
    'cameraDeviceSelect',
    'cameraHint',
    'cameraGuideFrame',
    'cameraGuide',
    'libraryInput',
    'submitButton',
    'fileName',
    'selectedFileCount',
    'selectedFileNames',
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
    cameraMessages: Object,
    cameraDeviceLabel: String,
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
    this.cameraCapture = new CameraCapture()
    this.cameraRequest = (this.cameraRequest || 0) + 1
    this.cameraDevices = new Map()
    this.cameraTracks = []
    this.cameraState = 'idle'
    this.cameraRotation = 0
    this.stopCameraForNavigation = this.stopCamera.bind(this)
    this.prepareUploadForCache = () => {
      this.stopCamera()
      this.resetUploadHeight()
    }
    this.stopCameraWhenHidden = () => {
      if (document.hidden) this.stopCamera()
    }
    this.refreshUploadControls = () => this.setCameraState(this.cameraState)
    this.cameraTrackEnded = () => this.showCameraError('unavailable')
    this.element.addEventListener('turbo:submit-start', this.refreshUploadControls)
    this.element.addEventListener('turbo:submit-end', this.refreshUploadControls)
    document.addEventListener('turbo:before-cache', this.prepareUploadForCache)
    document.addEventListener('visibilitychange', this.stopCameraWhenHidden)
    window.addEventListener('pagehide', this.stopCameraForNavigation)
    this.setCameraState('idle')

    if (this.cameraInputTarget.files.length > 0) {
      this.previewCamera()
    } else if (this.libraryInputTarget.files.length > 0) {
      this.previewLibrary()
    }
    this.setupUploadHeight()
  }

  disconnect () {
    this.stopCamera()
    this.resetUploadHeight()
    this.element.removeEventListener('turbo:submit-start', this.refreshUploadControls)
    this.element.removeEventListener('turbo:submit-end', this.refreshUploadControls)
    document.removeEventListener('turbo:before-cache', this.prepareUploadForCache)
    document.removeEventListener('visibilitychange', this.stopCameraWhenHidden)
    window.removeEventListener('pagehide', this.stopCameraForNavigation)
    this.revokePreviewUrl()
  }

  async openCamera () {
    if (this.uploadSubmitting() || !this.ocrAvailableValue || !['idle', 'error'].includes(this.cameraState)) return

    if (supportsInlineCamera({
      secureContext: window.isSecureContext,
      mediaDevices: navigator.mediaDevices,
      finePointer: window.matchMedia?.('(pointer: fine)')?.matches
    })) {
      await this.startCamera()
    } else {
      this.stopCamera()
      this.cameraInputTarget.click()
    }
  }

  async startCamera (deviceId) {
    this.stopCamera()
    const request = this.cameraRequest
    this.setCameraState('requesting')
    this.cameraCancelTarget.focus()

    try {
      const stream = await this.cameraCapture.start(deviceId)
      if (!stream || request !== this.cameraRequest) return

      this.cameraTracks = stream.getVideoTracks()
      this.cameraTracks.forEach((track) => track.addEventListener('ended', this.cameraTrackEnded))
      this.cameraVideoTarget.srcObject = stream
      await this.cameraVideoTarget.play()
      if (request !== this.cameraRequest) return

      this.setCameraState('live')
      this.cameraCaptureButtonTarget.focus()
      const devices = await this.cameraCapture.devices()
      if (request !== this.cameraRequest) return

      this.renderCameraDevices(devices, this.cameraTracks[0]?.getSettings().deviceId)
    } catch (error) {
      if (request !== this.cameraRequest) return

      this.showCameraError(error?.reason === 'permission' ? 'permission' : 'unavailable')
    }
  }

  async switchCamera (event) {
    if (!this.ocrAvailableValue || this.cameraState !== 'live') return

    const deviceId = this.cameraDevices.get(event.target.value)
    if (deviceId) await this.startCamera(deviceId)
  }

  renderCameraDevices (devices, currentDeviceId) {
    this.cameraDevices.clear()
    this.cameraDeviceSelectTarget.replaceChildren()
    this.cameraDeviceFieldTarget.classList.toggle('hidden', devices.length < 2)
    if (devices.length < 2) return

    devices.forEach((device, index) => {
      const key = `camera-${index}`
      this.cameraDevices.set(key, device.deviceId)
      const option = document.createElement('option')
      option.value = key
      option.textContent = device.label || this.cameraDeviceLabelValue.replace('%{number}', index + 1)
      option.selected = device.deviceId === currentDeviceId
      this.cameraDeviceSelectTarget.appendChild(option)
    })
  }

  async captureCamera () {
    if (!this.ocrAvailableValue || this.cameraState !== 'live') return

    this.syncCameraGuide()
    const guide = this.cameraGuideTarget.querySelector('[data-camera-guide]')
    if (this.cameraGuideTarget.classList.contains('invisible') || !guide) {
      this.showCameraError('capture')
      return
    }
    const guideBounds = guide.getBoundingClientRect()
    const request = this.cameraRequest
    this.setCameraState('capturing')
    try {
      const blob = await this.cameraCapture.capture(this.cameraVideoTarget, guideBounds, this.cameraRotation)
      if (request !== this.cameraRequest) return

      const file = new File([blob], 'receipt-camera.jpg', { type: 'image/jpeg' })
      const validationMessage = this.fileValidationMessage([file])
      if (validationMessage) {
        this.showCameraError('capture', validationMessage)
        return
      }

      if (!this.assignCapturedFile(file)) {
        this.showCameraError('capture')
        return
      }

      this.stopCamera()
      this.previewCamera()
      this.cameraButtonTarget.focus()
    } catch {
      if (request === this.cameraRequest) this.showCameraError('capture')
    }
  }

  assignCapturedFile (file) {
    const previousFiles = this.cameraInputTarget.files
    try {
      const dataTransfer = new DataTransfer()
      dataTransfer.items.add(file)
      this.cameraInputTarget.files = dataTransfer.files
      const assigned = this.cameraInputTarget.files
      if (assigned.length === 1 && assigned[0].name === file.name && assigned[0].size === file.size && assigned[0].type === file.type) return true
    } catch {
      // Some browsers do not allow assigning a captured file to an input.
    }

    try {
      this.cameraInputTarget.files = previousFiles
    } catch {
      // A rejected assignment leaves the browser-owned input unchanged.
    }
    return false
  }

  cameraFrameReady () {
    if (['live', 'capturing'].includes(this.cameraState)) {
      if (this.uploadHeightResize) this.uploadHeightResize()
      else this.syncCameraGuide()
    } else {
      this.cameraGuideTarget.classList.add('invisible')
    }
    const ready = this.cameraState === 'live' && this.cameraVideoTarget.readyState >= 2 && this.cameraVideoTarget.videoWidth > 0 && this.cameraVideoTarget.videoHeight > 0
    this.cameraCaptureButtonTarget.disabled = !ready || this.cameraGuideTarget.classList.contains('invisible')
    if (ready && !this.cameraHintStarted) {
      this.cameraHintStarted = true
      const request = this.cameraRequest
      this.cameraHintTimer = window.setTimeout(() => {
        if (request !== this.cameraRequest || this.cameraState !== 'live') return

        this.cameraHintTimer = null
        if (this.cameraHintTarget.contains(document.activeElement)) {
          this.cameraHintDismissPending = true
        } else {
          this.dismissCameraHint()
        }
      }, 5000)
    }
  }

  dismissCameraHint (event) {
    window.clearTimeout(this.cameraHintTimer)
    this.cameraHintTimer = null
    this.cameraHintStarted = true
    this.cameraHintDismissPending = false
    if (event && this.cameraHintTarget.contains(document.activeElement)) {
      const next = this.cameraCaptureButtonTarget.disabled ? this.cameraCancelTarget : this.cameraCaptureButtonTarget
      next.focus()
    }
    this.cameraHintTarget.classList.add('is-dismissed')
    this.cameraHintTarget.toggleAttribute('inert', true)
  }

  resumeCameraHintDismissal (event) {
    if (this.cameraHintDismissPending && !this.cameraHintTarget.contains(event.relatedTarget)) this.dismissCameraHint()
  }

  resetCameraHint () {
    window.clearTimeout(this.cameraHintTimer)
    this.cameraHintTimer = null
    this.cameraHintStarted = false
    this.cameraHintDismissPending = false
    this.cameraHintTarget.classList.remove('is-dismissed')
    this.cameraHintTarget.toggleAttribute('inert', false)
  }

  setupUploadHeight () {
    this.uploadLayout = this.element.closest('[data-receipt-upload-layout]')
    this.uploadCard = this.element.closest('[data-receipt-upload-card]')
    this.uploadGuidance = this.uploadLayout?.querySelector('[data-receipt-upload-guidance] > section')
    if (!this.uploadLayout || !this.uploadCard || !this.uploadGuidance) return

    this.uploadHeightResize = () => {
      if (this.uploadHeightFrame) return

      this.uploadHeightFrame = window.requestAnimationFrame(() => {
        this.uploadHeightFrame = null
        this.syncUploadHeight()
        this.syncCameraGuide()
      })
    }
    if (typeof window.ResizeObserver === 'function') {
      this.uploadHeightObserver = new window.ResizeObserver(this.uploadHeightResize)
      this.uploadHeightObserver.observe(this.uploadCard)
      this.uploadHeightObserver.observe(this.uploadGuidance)
      this.uploadHeightObserver.observe(this.cameraGuideFrameTarget)
    }
    window.addEventListener('resize', this.uploadHeightResize, { passive: true })
    window.visualViewport?.addEventListener('resize', this.uploadHeightResize)
    this.syncUploadHeight()
  }

  syncUploadHeight () {
    if (!this.uploadCard || !this.uploadGuidance) return

    const property = '--receipt-upload-stage-height'
    const guidance = this.uploadGuidance.getBoundingClientRect()
    const card = this.uploadCard.getBoundingClientRect()
    const stage = this.dropzoneTarget.getBoundingClientRect()
    const main = this.uploadLayout.closest('main')
    const bottomPadding = main ? Number.parseFloat(window.getComputedStyle(main).paddingBottom) || 0 : 0
    const headerHeight = document.querySelector('[data-component="header"]')?.getBoundingClientRect().height || 0
    const availableHeight = (window.visualViewport?.height || window.innerHeight) - headerHeight - bottomPadding
    const minimumHeight = Number.parseFloat(window.getComputedStyle(this.dropzoneTarget).minHeight) || 0
    const desktop = window.matchMedia('(min-width: 1024px)').matches && guidance.width > 0
    const preferredHeight = desktop ? Math.max(400, guidance.height - (card.height - stage.height)) : 400
    const height = Math.round(Math.max(minimumHeight, Math.min(preferredHeight, availableHeight)))
    const value = `${height}px`
    if (this.dropzoneTarget.style.getPropertyValue(property) !== value) this.dropzoneTarget.style.setProperty(property, value)
  }

  syncCameraGuide () {
    if (!['live', 'capturing'].includes(this.cameraState)) return

    const panel = this.cameraPanelTarget.getBoundingClientRect()
    const rotated = this.cameraRotation % 180 !== 0
    this.cameraVideoTarget.style.setProperty('width', `${rotated ? panel.height : panel.width}px`)
    this.cameraVideoTarget.style.setProperty('height', `${rotated ? panel.width : panel.height}px`)
    this.cameraVideoTarget.style.setProperty('--receipt-camera-rotation', `${this.cameraRotation}deg`)
    const outline = this.cameraGuideTarget.querySelector('.receipt-camera-guide-outline')
    const bounds = cameraGuideBounds({
      videoWidth: rotated ? this.cameraVideoTarget.videoHeight : this.cameraVideoTarget.videoWidth,
      videoHeight: rotated ? this.cameraVideoTarget.videoWidth : this.cameraVideoTarget.videoHeight,
      video: this.cameraVideoTarget.getBoundingClientRect(),
      frame: this.cameraGuideFrameTarget.getBoundingClientRect(),
      panel,
      inset: outline ? Number.parseFloat(window.getComputedStyle(outline).strokeWidth) / 2 : NaN
    })
    this.cameraGuideTarget.classList.toggle('invisible', !bounds)
    this.cameraCaptureButtonTarget.disabled = this.cameraState !== 'live' || this.cameraVideoTarget.readyState < 2 || !bounds
    if (!bounds) return

    Object.entries(bounds).forEach(([property, size]) => {
      const value = `${size}px`
      if (this.cameraGuideTarget.style.getPropertyValue(property) !== value) this.cameraGuideTarget.style.setProperty(property, value)
    })
  }

  resetUploadHeight () {
    this.uploadHeightObserver?.disconnect()
    this.uploadHeightObserver = null
    window.cancelAnimationFrame(this.uploadHeightFrame)
    this.uploadHeightFrame = null
    if (this.uploadHeightResize) {
      window.removeEventListener('resize', this.uploadHeightResize)
      window.visualViewport?.removeEventListener('resize', this.uploadHeightResize)
      this.uploadHeightResize = null
    }
    this.dropzoneTarget.style.removeProperty('--receipt-upload-stage-height')
    this.uploadLayout = null
    this.uploadCard = null
    this.uploadGuidance = null
  }

  cameraVideoFailed () {
    if (['requesting', 'live', 'capturing'].includes(this.cameraState)) this.showCameraError('unavailable')
  }

  cancelCamera () {
    this.stopCamera()
    this.cameraButtonTarget.focus()
  }

  handleCameraKeydown (event) {
    if (this.cameraState === 'idle' || this.uploadSubmitting() || event.defaultPrevented || event.isComposing || event.keyCode === 229 || event.repeat) return
    if (event.ctrlKey || event.altKey || event.metaKey || event.shiftKey) return
    if (event.target.isContentEditable || event.target.closest('input, textarea, select, [role="textbox"], [role="combobox"], [role="listbox"]')) return

    if (event.key === 'Escape') {
      event.preventDefault()
      event.stopPropagation()
      this.cancelCamera()
    } else if (event.key === ' ' && this.cameraState === 'live' && !this.cameraCaptureButtonTarget.disabled) {
      if (event.target.closest('button, a[href], summary, [role="button"]')) return

      event.preventDefault()
      event.stopPropagation()
      this.cameraCaptureButtonTarget.click()
    }
  }

  rotateCamera () {
    if (this.uploadSubmitting() || !this.ocrAvailableValue || this.cameraState !== 'live') return

    this.cameraRotation = (this.cameraRotation + 90) % 360
    this.syncCameraGuide()
  }

  stopCamera () {
    this.cameraRequest += 1
    this.cameraRotation = 0
    ;['width', 'height', '--receipt-camera-rotation'].forEach((property) => this.cameraVideoTarget.style.removeProperty(property))
    this.resetCameraHint()
    this.cameraTracks.forEach((track) => track.removeEventListener('ended', this.cameraTrackEnded))
    this.cameraTracks = []
    this.cameraCapture.stop()
    this.cameraVideoTarget.pause()
    this.cameraVideoTarget.srcObject = null
    this.cameraDevices.clear()
    this.cameraDeviceSelectTarget.replaceChildren()
    this.cameraDeviceFieldTarget.classList.add('hidden')
    this.setCameraState('idle')
  }

  showCameraError (reason, help) {
    this.stopCamera()
    this.setCameraState('error')
    this.cameraStatusTitleTarget.textContent = this.cameraMessagesValue[reason].title
    this.cameraStatusHelpTarget.textContent = help || this.cameraMessagesValue[reason].help
    this.cameraRetryTarget.focus()
  }

  setCameraState (state) {
    this.cameraState = state
    const active = state !== 'idle'
    const live = ['live', 'capturing'].includes(state)
    this.element.dataset.receiptUploadCameraActive = String(active)
    this.cameraPanelTarget.classList.toggle('hidden', !active)
    this.cameraPanelTarget.classList.toggle('flex', active)
    this.cameraPanelTarget.setAttribute('aria-busy', String(state === 'requesting' || state === 'capturing'))
    this.cameraLiveTarget.classList.toggle('hidden', !live)
    this.cameraLiveTarget.classList.toggle('grid', live)
    this.cameraVideoTarget.classList.toggle('hidden', !live)
    this.cameraStatusTarget.classList.toggle('hidden', live)
    this.cameraStatusTarget.setAttribute('role', state === 'error' ? 'alert' : 'status')
    this.cameraRetryTarget.classList.toggle('hidden', state !== 'error')
    this.cameraRetryTarget.classList.toggle('inline-flex', state === 'error')
    this.cameraCaptureButtonTarget.classList.toggle('hidden', !live)
    this.cameraCaptureButtonTarget.classList.toggle('inline-flex', live)
    this.cameraRotateTarget.classList.toggle('hidden', !live)
    this.cameraRotateTarget.classList.toggle('inline-flex', live)
    this.cameraRotateTarget.disabled = state !== 'live' || this.uploadSubmitting() || !this.ocrAvailableValue
    this.cameraRetryTarget.disabled = !this.ocrAvailableValue
    this.cameraDeviceSelectTarget.disabled = state !== 'live'
    this.cameraButtonTarget.disabled = this.uploadSubmitting() || !this.ocrAvailableValue || active
    this.previewWrapperTarget.classList.toggle('hidden', active || this.selectedFiles.length === 0)
    this.emptyStateTarget.classList.toggle('hidden', active || this.selectedFiles.length > 0)
    this.submitButtonTarget.disabled = this.uploadSubmitting() || active || !this.ocrAvailableValue || this.selectedFiles.length === 0
    if (state === 'requesting') {
      this.cameraStatusTitleTarget.textContent = this.cameraMessagesValue.requesting.title
      this.cameraStatusHelpTarget.textContent = this.cameraMessagesValue.requesting.help
    }
    this.cameraFrameReady()
  }

  ocrAvailableValueChanged () {
    if (!this.cameraCapture) return

    if (!this.ocrAvailableValue) this.stopCamera()
    this.setCameraState(this.cameraState)
  }

  openLibrary () {
    if (!this.ocrAvailableValue) return

    this.stopCamera()
    this.libraryInputTarget.click()
  }

  previewCamera () {
    this.stopCamera()
    if (this.cameraInputTarget.files.length === 0) return

    this.libraryInputTarget.value = ''
    this.previewFiles(this.cameraInputTarget.files, { single: true })
  }

  previewLibrary () {
    this.stopCamera()
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
    this.stopCamera()
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

  disableSubmit (event) {
    if (this.uploadSubmitting()) {
      event.preventDefault()
      return
    }

    if (this.cameraState !== 'idle') {
      event.preventDefault()
      this.stopCamera()
      return
    }

    this.stopCamera()
    this.submitButtonTarget.disabled = true
  }

  uploadSubmitting () {
    return this.element.getAttribute('aria-busy') === 'true'
  }

  previewFiles (fileList, { single = false } = {}) {
    const files = Array.from(fileList || [])
    const selectedFiles = single ? files.slice(0, 1) : files
    this.submitButtonTarget.disabled = this.uploadSubmitting() || selectedFiles.length === 0 || !this.ocrAvailableValue

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
    this.updateSelectedFilesMessage(files)
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
    const message = this.fileValidationMessage(files)
    if (message) {
      this.showFileError(message)
      return false
    }

    return true
  }

  fileValidationMessage (files) {
    if (files.length > this.maxFileCountValue) return this.maxFileCountMessageValue
    if (files.some((file) => !this.isImageFile(file))) return this.invalidImageMessageValue
    if (this.exceedsStorageQuota(files)) return this.quotaExceededMessageValue

    return null
  }

  selectedFilesSummaryText (files) {
    return this.selectedFilesMessageValue
      .replace('%{count}', files.length)
      .replace(/[:：]\s*%\{files\}/, '')
      .replace('%{files}', '')
      .trim()
  }

  updateSelectedFilesMessage (files) {
    const fileNames = files.map((file) => file.name)
    const fullLabel = fileNames.join(', ')

    this.fileNameTarget.setAttribute('aria-label', fullLabel)

    if (files.length === 1) {
      this.selectedFileCountTarget.textContent = fileNames[0]
      this.selectedFileCountTarget.title = fileNames[0]
      this.selectedFileNamesTarget.textContent = ''
      this.selectedFileNamesTarget.removeAttribute('title')
      this.selectedFileNamesTarget.classList.add('hidden')
      return
    }

    this.selectedFileCountTarget.textContent = this.selectedFilesSummaryText(files)
    this.selectedFileCountTarget.removeAttribute('title')
    this.selectedFileNamesTarget.textContent = fullLabel
    this.selectedFileNamesTarget.title = fileNames.join('\n')
    this.selectedFileNamesTarget.classList.remove('hidden')
  }

  updateFileStatusMessage (message) {
    this.fileNameTarget.removeAttribute('aria-label')
    this.selectedFileCountTarget.textContent = message
    this.selectedFileCountTarget.removeAttribute('title')
    this.selectedFileNamesTarget.textContent = ''
    this.selectedFileNamesTarget.removeAttribute('title')
    this.selectedFileNamesTarget.classList.add('hidden')
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
    this.updateFileStatusMessage(message)
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
    this.updateFileStatusMessage(this.emptyFileMessageValue)
    this.hidePreviewControls()
  }

  revokePreviewUrl () {
    if (!this.previewObjectUrl) return

    URL.revokeObjectURL(this.previewObjectUrl)
    this.previewObjectUrl = null
  }
}
