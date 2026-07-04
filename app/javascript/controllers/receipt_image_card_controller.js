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

const DESKTOP_PREVIEW_MEDIA_QUERY = '(min-width: 1024px)'
const REVIEW_REASON_TARGET_LINK_SELECTOR = 'a[data-review-reason-target-link]'
const IMAGE_PREVIEW_REVIEW_TARGET = 'receipt-section-image-preview'

function isAllowedReceiptImageFile (file) {
  if (!file) return false

  const type = file.type?.toLowerCase()
  if (type) return ALLOWED_RECEIPT_IMAGE_TYPES.includes(type)

  const name = file.name?.toLowerCase() || ''
  return ALLOWED_RECEIPT_IMAGE_EXTENSIONS.some((extension) => name.endsWith(extension))
}

// Connects to data-controller="receipt-image-card"
export default class extends Controller {
  static targets = ['content', 'chevron', 'toggleButton', 'modal', 'fileInput', 'previewImage', 'modalImage', 'fileName', 'dropOverlay', 'uploadError', 'removeImageField']
  static values = {
    initiallyOpen: Boolean,
    collapseOnMobile: Boolean,
    unselectedLabel: { type: String, default: 'Unselected' },
    emptyFileLabel: { type: String, default: 'No file selected' },
    quotaExceededMessage: { type: String, default: 'Storage quota exceeded.' },
    storageUsedBytes: { type: Number, default: 0 },
    storageLimitBytes: { type: Number, default: 0 },
    storageExcludingBlobBytes: { type: Number, default: 0 }
  }

  connect () {
    this.userHasToggled = false
    this.previewBreakpointMediaQuery = this.buildPreviewBreakpointMediaQuery()
    this.isOpen = this.defaultOpenStateForCurrentBreakpoint()
    this.objectUrl = null
    this.dragDepth = 0
    this.modalElement = this.hasModalTarget ? this.modalTarget : null
    this.modalImageElement = this.hasModalImageTarget ? this.modalImageTarget : null
    this.defaultUploadErrorMessage = this.hasUploadErrorTarget ? this.uploadErrorTarget.textContent.trim() : ''
    this.modalPlaceholder = document.createComment('receipt-image-modal-placeholder')
    this.handleBeforeCache = this.handleBeforeCache.bind(this)
    this.handleBreakpointChange = this.handleBreakpointChange.bind(this)
    this.handleReviewTargetClick = this.handleReviewTargetClick.bind(this)
    this.handleReviewTargetHashChange = this.handleReviewTargetHashChange.bind(this)
    this.sync()

    this.initializeFileName()

    this.handleKeydown = this.handleKeydown.bind(this)
    this.handleModalCloseClick = this.handleModalCloseClick.bind(this)
    this.handleModalPanelClick = this.handleModalPanelClick.bind(this)
    document.addEventListener('keydown', this.handleKeydown)
    document.addEventListener('turbo:before-cache', this.handleBeforeCache)
    document.addEventListener('click', this.handleReviewTargetClick)
    window.addEventListener('hashchange', this.handleReviewTargetHashChange)
    this.addBreakpointListener()
    this.addModalEventListeners()
    this.openFromReviewTargetHash()
  }

  disconnect () {
    this.removeBreakpointListener()
    this.removeModalEventListeners()
    this.restoreModal()
    this.unlockBodyScroll()
    this.revokeObjectUrl()
    document.removeEventListener('keydown', this.handleKeydown)
    document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
    document.removeEventListener('click', this.handleReviewTargetClick)
    window.removeEventListener('hashchange', this.handleReviewTargetHashChange)
  }

  buildPreviewBreakpointMediaQuery () {
    if (!window.matchMedia) return null

    return window.matchMedia(DESKTOP_PREVIEW_MEDIA_QUERY)
  }

  defaultOpenStateForCurrentBreakpoint () {
    if (!this.initiallyOpenValue) return false
    if (!this.collapseOnMobileValue) return true

    return this.matchesDesktopPreviewBreakpoint()
  }

  matchesDesktopPreviewBreakpoint () {
    return !this.previewBreakpointMediaQuery || this.previewBreakpointMediaQuery.matches
  }

  addBreakpointListener () {
    if (!this.collapseOnMobileValue || !this.previewBreakpointMediaQuery) return

    if (this.previewBreakpointMediaQuery.addEventListener) {
      this.previewBreakpointMediaQuery.addEventListener('change', this.handleBreakpointChange)
    } else {
      this.previewBreakpointMediaQuery.addListener(this.handleBreakpointChange)
    }
  }

  removeBreakpointListener () {
    if (!this.collapseOnMobileValue || !this.previewBreakpointMediaQuery) return

    if (this.previewBreakpointMediaQuery.removeEventListener) {
      this.previewBreakpointMediaQuery.removeEventListener('change', this.handleBreakpointChange)
    } else {
      this.previewBreakpointMediaQuery.removeListener(this.handleBreakpointChange)
    }
  }

  handleBreakpointChange () {
    if (this.userHasToggled) return

    this.isOpen = this.defaultOpenStateForCurrentBreakpoint()
    this.sync()
  }

  previewSelectedImage (event) {
    this.previewFile(event.target.files?.[0])
  }

  previewFile (file) {
    if (!file) return

    if (!isAllowedReceiptImageFile(file)) {
      this.clearFileInput()
      this.showUploadError()
      return
    }

    if (this.exceedsStorageQuota(file)) {
      this.clearFileInput()
      this.showUploadError(this.quotaExceededMessageValue)
      return
    }

    this.updateFileName(file.name)
    this.hideUploadError()
    this.clearRemoveImageRequest()

    this.revokeObjectUrl()
    this.objectUrl = URL.createObjectURL(file)

    if (this.hasPreviewImageTarget) {
      this.previewImageTarget.src = this.objectUrl
      this.previewImageTarget.classList.remove('hidden')

      // placeholder（親要素内のテキスト等）を非表示にする
      const container = this.previewImageTarget.closest('.relative')
      if (container) {
        const texts = container.querySelectorAll('span, p')
        texts.forEach(el => el.classList.add('hidden'))
      }
    }

    if (this.modalImageElement) {
      this.modalImageElement.src = this.objectUrl
    }
  }

  updateFileName (fileName) {
    if (!this.hasFileNameTarget) return

    const label = fileName || this.unselectedLabelValue
    this.fileNameTarget.textContent = label

    if (fileName) {
      this.fileNameTarget.title = fileName
    } else {
      this.fileNameTarget.removeAttribute('title')
    }
  }

  showUploadError (message = this.defaultUploadErrorMessage) {
    if (!this.hasUploadErrorTarget) return

    if (message) {
      this.uploadErrorTarget.textContent = message
    }
    this.uploadErrorTarget.classList.remove('hidden')
  }

  hideUploadError () {
    if (!this.hasUploadErrorTarget) return

    this.uploadErrorTarget.classList.add('hidden')
  }

  initializeFileName () {
    if (!this.hasFileNameTarget) return

    const initial = this.fileNameTarget.dataset.initialLabel
    if (initial) {
      this.fileNameTarget.textContent = initial
    } else {
      this.fileNameTarget.textContent = this.emptyFileLabelValue
    }
    this.fileNameTarget.removeAttribute('title')
  }

  handleDragOver (event) {
    event.preventDefault()
  }

  showDropOverlay () {
    if (!this.hasDropOverlayTarget) return

    this.dropOverlayTarget.classList.remove('hidden')
    this.dropOverlayTarget.classList.add('flex')
  }

  hideDropOverlay () {
    if (!this.hasDropOverlayTarget) return

    this.dropOverlayTarget.classList.add('hidden')
    this.dropOverlayTarget.classList.remove('flex')
  }

  handleDragEnter (event) {
    event.preventDefault()
    this.dragDepth += 1
    this.showDropOverlay()
    this.hideUploadError()
  }

  handleDragLeave (event) {
    event.preventDefault()
    this.dragDepth = Math.max(0, this.dragDepth - 1)
    if (this.dragDepth === 0) {
      this.hideDropOverlay()
    }
  }

  handleDrop (event) {
    event.preventDefault()

    this.dragDepth = 0
    this.hideDropOverlay()

    const file = event.dataTransfer?.files?.[0]
    if (!isAllowedReceiptImageFile(file)) {
      this.showUploadError()
      return
    }

    if (this.exceedsStorageQuota(file)) {
      this.clearFileInput()
      this.showUploadError(this.quotaExceededMessageValue)
      return
    }

    this.hideUploadError()

    // fileInputに反映
    if (this.hasFileInputTarget) {
      const dataTransfer = new DataTransfer()
      dataTransfer.items.add(file)
      this.fileInputTarget.files = dataTransfer.files
    }

    this.previewFile(file)
  }

  toggleRemoveImage () {
    if (!this.hasRemoveImageFieldTarget || !this.removeImageFieldTarget.checked) return

    this.hideUploadError()
    this.clearFileInput()
    this.revokeObjectUrl()
    if (this.hasFileNameTarget) {
      this.updateFileName(this.fileNameTarget.dataset.initialLabel || this.emptyFileLabelValue)
    }
  }

  clearRemoveImageRequest () {
    if (!this.hasRemoveImageFieldTarget) return

    this.removeImageFieldTarget.checked = false
  }

  clearFileInput () {
    if (!this.hasFileInputTarget) return

    this.fileInputTarget.value = ''
  }

  exceedsStorageQuota (file) {
    if (!file || this.storageLimitBytesValue <= 0) return false

    const candidateUsedBytes = this.storageUsedBytesValue - this.storageExcludingBlobBytesValue + file.size
    return candidateUsedBytes > this.storageLimitBytesValue
  }

  handleReviewTargetClick (event) {
    const link = event.target?.closest?.(REVIEW_REASON_TARGET_LINK_SELECTOR)
    if (!link) return

    const url = this.reviewTargetUrl(link.getAttribute('href'))
    if (!url || !this.samePageReviewTargetUrl(url)) return

    const targetId = this.reviewTargetIdFromHash(url.hash)
    if (!this.imagePreviewReviewTargetId(targetId)) return
    if (!this.containsImagePreviewReviewTarget(targetId)) return

    if (window.location.hash !== this.reviewTargetHash(targetId)) {
      this.openPreview({ userDirected: true })
      return
    }

    event.preventDefault()
    this.openPreview({ userDirected: true })
    this.replaceReviewTargetHash(targetId)
  }

  handleReviewTargetHashChange () {
    this.openFromReviewTargetHash({ scroll: true })
  }

  reviewTargetUrl (href) {
    try {
      return new URL(href || '', window.location.href)
    } catch {
      return null
    }
  }

  samePageReviewTargetUrl (url) {
    return url.origin === window.location.origin &&
      url.pathname === window.location.pathname &&
      url.search === window.location.search
  }

  reviewTargetIdFromHash (hash) {
    const targetId = String(hash || '').replace(/^#/, '')
    if (targetId === '') return null

    try {
      return decodeURIComponent(targetId)
    } catch {
      return targetId
    }
  }

  imagePreviewReviewTargetId (targetId) {
    return targetId === IMAGE_PREVIEW_REVIEW_TARGET
  }

  containsImagePreviewReviewTarget (targetId) {
    const section = document.getElementById(targetId)
    return Boolean(section?.contains(this.element))
  }

  openFromReviewTargetHash ({ scroll = true } = {}) {
    const targetId = this.reviewTargetIdFromHash(window.location.hash)
    if (!this.imagePreviewReviewTargetId(targetId)) return false
    if (!this.containsImagePreviewReviewTarget(targetId)) return false

    return this.openFromReviewTarget({ scroll })
  }

  openFromReviewTarget ({ scroll = true } = {}) {
    this.openPreview({ userDirected: true })
    if (scroll) this.scrollReviewTargetIntoView()

    return true
  }

  openPreview ({ userDirected = false } = {}) {
    if (userDirected) this.userHasToggled = true

    this.isOpen = true
    this.sync()
  }

  reviewTargetHash (targetId) {
    return `#${encodeURIComponent(targetId)}`
  }

  replaceReviewTargetHash (targetId) {
    if (typeof window.history?.replaceState !== 'function' || typeof window.location?.replace !== 'function') {
      this.openFromReviewTarget({ scroll: true })
      return
    }

    const path = `${window.location.pathname}${window.location.search}`
    window.history.replaceState(null, '', path)
    window.location.replace(`${path}${this.reviewTargetHash(targetId)}`)
  }

  scrollReviewTargetIntoView () {
    const section = document.getElementById(IMAGE_PREVIEW_REVIEW_TARGET)
    const target = this.reviewScrollTarget() || section
    if (!target || typeof target.scrollIntoView !== 'function') return

    window.requestAnimationFrame(() => {
      if (target === section || !section) {
        target.scrollIntoView({ behavior: 'smooth', block: 'start', inline: 'nearest' })
        return
      }

      section.scrollIntoView({ behavior: 'auto', block: 'start', inline: 'nearest' })
      window.requestAnimationFrame(() => {
        this.centerReviewScrollTarget(target)
      })
    })
  }

  reviewScrollTarget () {
    if (this.hasPreviewImageTarget && !this.previewImageTarget.classList.contains('hidden')) return this.previewImageTarget
    if (this.hasContentTarget) return this.contentTarget

    return null
  }

  centerReviewScrollTarget (target) {
    if (!target || typeof window.scrollBy !== 'function') return

    const rect = target.getBoundingClientRect()
    const desiredTop = Math.max(24, (window.innerHeight - rect.height) / 2)
    const delta = rect.top - desiredTop
    if (Math.abs(delta) < 16) return

    window.scrollBy({ top: delta, behavior: 'smooth' })
  }

  revokeObjectUrl () {
    if (this.objectUrl) {
      URL.revokeObjectURL(this.objectUrl)
      this.objectUrl = null
    }
  }

  toggle () {
    this.userHasToggled = true
    this.isOpen = !this.isOpen
    this.sync()
  }

  openModal () {
    if (!this.modalElement || !this.modalImageElement) return
    if (!this.modalElement.classList.contains('hidden')) return

    this.moveModalToBody()
    this.modalElement.classList.remove('hidden')
    this.modalElement.setAttribute('aria-hidden', 'false')
    this.lockBodyScroll()
    this.modalElement.focus()
  }

  closeModal () {
    if (!this.modalElement) return

    this.modalElement.classList.add('hidden')
    this.modalElement.setAttribute('aria-hidden', 'true')
    this.unlockBodyScroll()
    this.restoreModal()
  }

  handleKeydown (e) {
    if (e.key !== 'Escape') return
    if (!this.modalElement || this.modalElement.classList.contains('hidden')) return

    this.closeModal()
  }

  handleBeforeCache () {
    if (this.modalElement && !this.modalElement.classList.contains('hidden')) {
      this.closeModal()
    }

    this.sync()
  }

  handleModalCloseClick (event) {
    event.preventDefault()
    this.closeModal()
  }

  handleModalPanelClick (event) {
    event.stopPropagation()
  }

  stopPropagation (e) {
    e.stopPropagation()
  }

  addModalEventListeners () {
    if (!this.modalElement) return

    this.modalOverlayElement = this.modalElement.querySelector('[data-receipt-image-card-modal-part="overlay"]')
    this.modalContainerElement = this.modalElement.querySelector('[data-receipt-image-card-modal-part="container"]')
    this.modalPanelElement = this.modalElement.querySelector('[data-receipt-image-card-modal-part="panel"]')
    this.modalCloseElement = this.modalElement.querySelector('[data-receipt-image-card-modal-part="close"]')

    this.modalOverlayElement?.addEventListener('click', this.handleModalCloseClick)
    this.modalContainerElement?.addEventListener('click', this.handleModalCloseClick)
    this.modalCloseElement?.addEventListener('click', this.handleModalCloseClick)
    this.modalPanelElement?.addEventListener('click', this.handleModalPanelClick)
  }

  removeModalEventListeners () {
    this.modalOverlayElement?.removeEventListener('click', this.handleModalCloseClick)
    this.modalContainerElement?.removeEventListener('click', this.handleModalCloseClick)
    this.modalCloseElement?.removeEventListener('click', this.handleModalCloseClick)
    this.modalPanelElement?.removeEventListener('click', this.handleModalPanelClick)
  }

  moveModalToBody () {
    if (!this.modalElement || this.modalElement.parentNode === document.body) return

    if (!this.modalPlaceholder.parentNode) {
      this.modalElement.parentNode.insertBefore(this.modalPlaceholder, this.modalElement)
    }

    document.body.appendChild(this.modalElement)
  }

  restoreModal () {
    if (!this.modalElement) return

    if (!this.modalPlaceholder.parentNode) {
      if (this.modalElement.parentNode === document.body) {
        this.modalElement.remove()
      }
      return
    }

    this.modalPlaceholder.parentNode.insertBefore(this.modalElement, this.modalPlaceholder)
    this.modalPlaceholder.remove()
  }

  sync () {
    if (this.hasContentTarget) {
      this.contentTarget.classList.toggle('is-open', this.isOpen)
      this.contentTarget.toggleAttribute('inert', !this.isOpen)
      this.contentTarget.setAttribute('aria-hidden', String(!this.isOpen))
    }

    if (this.hasChevronTarget) {
      this.chevronTarget.classList.toggle('rotate-180', this.isOpen)
    }

    if (this.hasToggleButtonTarget) {
      this.toggleButtonTarget.setAttribute('aria-expanded', String(this.isOpen))
    }
  }

  lockBodyScroll () {
    document.body.classList.add('overflow-hidden')
  }

  unlockBodyScroll () {
    document.body.classList.remove('overflow-hidden')
  }
}
