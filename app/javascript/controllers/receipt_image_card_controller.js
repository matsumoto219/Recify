/* global DataTransfer */
import { Controller } from '@hotwired/stimulus'

// Connects to data-controller="receipt-image-card"
export default class extends Controller {
  static targets = ['content', 'chevron', 'toggleButton', 'modal', 'fileInput', 'previewImage', 'modalImage', 'fileName', 'dropOverlay', 'uploadError']
  static values = { initiallyOpen: Boolean }

  connect () {
    this.isOpen = this.initiallyOpenValue
    this.objectUrl = null
    this.dragDepth = 0
    this.sync()

    this.initializeFileName()

    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener('keydown', this.handleKeydown)
  }

  disconnect () {
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

    if (this.hasModalImageTarget) {
      this.modalImageTarget.src = this.objectUrl
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

  handleDragEnter (event) {
    event.preventDefault()
    this.dragDepth += 1
    this.element.classList.add('ring-2', 'ring-[#C0C1FF]/50', 'rounded-xl')

    if (this.hasDropOverlayTarget) {
      this.dropOverlayTarget.classList.remove('hidden')
      this.dropOverlayTarget.classList.add('flex')
    }

    this.hideUploadError()
  }

  handleDragLeave (event) {
    event.preventDefault()
    this.dragDepth = Math.max(0, this.dragDepth - 1)
    if (this.dragDepth === 0) {
      this.element.classList.remove('ring-2', 'ring-[#C0C1FF]/50', 'rounded-xl')

      if (this.hasDropOverlayTarget) {
        this.dropOverlayTarget.classList.add('hidden')
        this.dropOverlayTarget.classList.remove('flex')
      }
    }
  }

  handleDrop (event) {
    event.preventDefault()

    this.dragDepth = 0
    this.element.classList.remove('ring-2', 'ring-[#C0C1FF]/50', 'rounded-xl')

    if (this.hasDropOverlayTarget) {
      this.dropOverlayTarget.classList.add('hidden')
      this.dropOverlayTarget.classList.remove('flex')
    }

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
    if (!this.hasModalTarget || !this.hasModalImageTarget) return
    if (!this.modalTarget.classList.contains('hidden')) return

    this.modalTarget.classList.remove('hidden')
    this.modalTarget.setAttribute('aria-hidden', 'false')
    this.lockBodyScroll()
    this.modalTarget.focus()
  }

  closeModal () {
    if (!this.hasModalTarget) return

    this.modalTarget.classList.add('hidden')
    this.modalTarget.setAttribute('aria-hidden', 'true')
    this.unlockBodyScroll()
  }

  handleKeydown (e) {
    if (e.key !== 'Escape') return
    if (!this.hasModalTarget || this.modalTarget.classList.contains('hidden')) return

    this.closeModal()
  }

  stopPropagation (e) {
    e.stopPropagation()
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
