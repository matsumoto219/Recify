import { Controller } from '@hotwired/stimulus'

const FOCUSABLE_SELECTOR = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])'
].join(',')

// Connects to data-controller="legal-dialog"
export default class extends Controller {
  static targets = ['dialog']

  connect () {
    this.activeDialog = null
    this.restoreFocusElement = null
    this.previousBodyOverflow = null
  }

  disconnect () {
    this.closeActiveDialog()
    this.unlockBodyScroll()
  }

  open (event) {
    const dialog = this.findDialog(event.params.dialog)

    if (!dialog || typeof dialog.showModal !== 'function') return

    event.preventDefault()
    this.restoreFocusElement = event.currentTarget
    this.activeDialog = dialog
    this.lockBodyScroll()
    dialog.showModal()
    this.focusInitialElement(dialog)
  }

  close (event) {
    event?.preventDefault()
    const dialog = event?.currentTarget?.closest('dialog') || this.activeDialog

    if (!dialog) return
    if (dialog.open) {
      dialog.close()
    } else {
      this.handleDialogClosed(dialog)
    }
  }

  closeBackdrop (event) {
    if (event.target !== event.currentTarget) return

    this.close(event)
  }

  handleCancel () {
    this.unlockBodyScroll()
  }

  handleClose (event) {
    this.handleDialogClosed(event.target)
  }

  handleKeydown (event) {
    if (event.key === 'Escape') {
      event.preventDefault()
      this.close(event)
      return
    }

    if (event.key !== 'Tab') return

    this.trapFocus(event)
  }

  findDialog (name) {
    return this.dialogTargets.find((dialog) => dialog.dataset.legalDialogName === name)
  }

  focusInitialElement (dialog) {
    requestAnimationFrame(() => {
      const focusableElements = this.focusableElements(dialog)
      const initialElement = focusableElements[0] || dialog
      initialElement.focus()
    })
  }

  trapFocus (event) {
    const dialog = event.currentTarget
    const focusableElements = this.focusableElements(dialog)

    if (focusableElements.length === 0) {
      event.preventDefault()
      dialog.focus()
      return
    }

    const firstElement = focusableElements[0]
    const lastElement = focusableElements[focusableElements.length - 1]

    if (event.shiftKey && document.activeElement === firstElement) {
      event.preventDefault()
      lastElement.focus()
    } else if (!event.shiftKey && document.activeElement === lastElement) {
      event.preventDefault()
      firstElement.focus()
    }
  }

  focusableElements (dialog) {
    return Array.from(dialog.querySelectorAll(FOCUSABLE_SELECTOR)).filter((element) => {
      if (element.hasAttribute('disabled')) return false
      if (element.getAttribute('aria-hidden') === 'true') return false

      const style = window.getComputedStyle(element)
      return style.display !== 'none' && style.visibility !== 'hidden'
    })
  }

  handleDialogClosed (dialog) {
    if (this.activeDialog !== dialog) return

    this.activeDialog = null
    this.unlockBodyScroll()
    this.restoreFocus()
  }

  closeActiveDialog () {
    if (!this.activeDialog) return

    if (this.activeDialog.open) {
      this.activeDialog.close()
    } else {
      this.handleDialogClosed(this.activeDialog)
    }
  }

  lockBodyScroll () {
    if (this.previousBodyOverflow !== null) return

    this.previousBodyOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
  }

  unlockBodyScroll () {
    if (this.previousBodyOverflow === null) return

    document.body.style.overflow = this.previousBodyOverflow
    this.previousBodyOverflow = null
  }

  restoreFocus () {
    if (!this.restoreFocusElement?.isConnected) {
      this.restoreFocusElement = null
      return
    }

    this.restoreFocusElement.focus()
    this.restoreFocusElement = null
  }
}
