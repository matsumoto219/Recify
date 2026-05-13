import { Controller } from '@hotwired/stimulus'

// Connects to data-controller="receipt-image-card"
export default class extends Controller {
  static targets = ['content', 'chevron', 'toggleButton', 'modal', 'fileInput', 'previewImage', 'modalImage', 'fileName', 'dropOverlay', 'uploadError']
  static values = { initiallyOpen: Boolean }

  connect () {
    this.isOpen = this.initiallyOpenValue
    this.objectUrl = null
    this.dragDepth = 0
    this.modalElement = this.hasModalTarget ? this.modalTarget : null
    this.modalImageElement = this.hasModalImageTarget ? this.modalImageTarget : null
    this.modalPlaceholder = document.createComment('receipt-image-modal-placeholder')
    this.sync()

    this.initializeFileName()

    this.handleKeydown = this.handleKeydown.bind(this)
    this.handleModalCloseClick = this.handleModalCloseClick.bind(this)
    this.handleModalPanelClick = this.handleModalPanelClick.bind(this)
    document.addEventListener('keydown', this.handleKeydown)
    this.addModalEventListeners()
  }

  disconnect () {
    this.removeModalEventListeners()
    this.restoreModal()
    this.unlockBodyScroll()
    this.revokeObjectUrl()
    document.removeEventListener('keydown', this.handleKeydown)
  }

  previewSelectedImage (event) {
    this.previewFile(event.target.files?.[0])
  }

  previewFile (file) {
    if (!file || !file.type.startsWith('image/')) return

    this.updateFileName(file.name)
    this.hideUploadError()

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

    this.fileNameTarget.textContent = fileName || '未選択'
  }

  showUploadError () {
    if (!this.hasUploadErrorTarget) return

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
      this.fileNameTarget.textContent = 'ファイル未選択'
    }
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
    if (!file || !file.type.startsWith('image/')) {
      this.showUploadError()
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

  revokeObjectUrl () {
    if (this.objectUrl) {
      URL.revokeObjectURL(this.objectUrl)
      this.objectUrl = null
    }
  }

  toggle () {
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
      this.contentTarget.classList.toggle('hidden', !this.isOpen)
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
