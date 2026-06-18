import { Turbo } from '@hotwired/turbo-rails'

const FOCUSABLE_SELECTOR = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])'
].join(',')

const ALLOWED_VARIANTS = new Set(['neutral', 'danger'])
const ALLOWED_BACKDROPS = new Set(['blur', 'plain', 'none'])
const ALLOWED_ICONS = new Set(['help', 'logout', 'delete', 'security', 'passkey', 'key', 'warning'])
const MATERIAL_ICON_SELECTOR = '.material-symbols-outlined, [aria-hidden="true"]'
const METHOD_OVERRIDE_SELECTOR = 'input[name="_method"]'

class RecifyConfirmDialog {
  constructor () {
    this.dialog = null
    this.resolve = null
    this.restoreFocusElement = null
    this.previousBodyOverflow = null
    this.boundDialog = null
    this.documentListenersBound = false

    this.handleCancel = this.handleCancel.bind(this)
    this.handleConfirm = this.handleConfirm.bind(this)
    this.handleNativeCancel = this.handleNativeCancel.bind(this)
    this.handleClose = this.handleClose.bind(this)
    this.handleKeydown = this.handleKeydown.bind(this)
    this.handleBeforeCache = this.handleBeforeCache.bind(this)
  }

  confirm (message, formElement, submitter) {
    const dialog = this.ensureDialog()

    if (!dialog || typeof dialog.showModal !== 'function') return Promise.resolve(false)

    if (this.resolve) this.finish(false)

    this.restoreFocusElement = this.focusRestoreTarget(submitter, formElement)
    this.applyContent({ message, formElement, submitter })
    this.lockBodyScroll()
    dialog.showModal()
    this.focusCancelButton()

    return new Promise((resolve) => {
      this.resolve = resolve
    })
  }

  ensureDialog () {
    if (this.dialog?.isConnected) return this.dialog

    const dialog = document.querySelector('[data-confirm-dialog]')
    if (!dialog) return null

    this.dialog = dialog
    this.cacheElements()
    this.bindListeners()

    return this.dialog
  }

  cacheElements () {
    this.titleElement = this.dialog.querySelector('[data-confirm-dialog-title]')
    this.messageElement = this.dialog.querySelector('[data-confirm-dialog-message]')
    this.iconElement = this.dialog.querySelector('[data-confirm-dialog-icon]')
    this.cancelButton = this.dialog.querySelector('[data-confirm-dialog-cancel][type="button"]')
    this.confirmButton = this.dialog.querySelector('[data-confirm-dialog-confirm]')
  }

  bindListeners () {
    if (this.boundDialog !== this.dialog) {
      this.dialog.querySelectorAll('[data-confirm-dialog-cancel]').forEach((element) => {
        element.addEventListener('click', this.handleCancel)
      })
      this.confirmButton?.addEventListener('click', this.handleConfirm)
      this.dialog.addEventListener('cancel', this.handleNativeCancel)
      this.dialog.addEventListener('close', this.handleClose)
      this.dialog.addEventListener('keydown', this.handleKeydown)
      this.boundDialog = this.dialog
    }

    if (!this.documentListenersBound) {
      document.addEventListener('turbo:before-cache', this.handleBeforeCache)
      this.documentListenersBound = true
    }
  }

  applyContent ({ message, formElement, submitter }) {
    const variant = this.confirmVariant(formElement, submitter)
    const labels = this.dialog.dataset
    const title = this.confirmTitle(formElement, submitter, labels, variant)
    const confirmLabel = this.confirmLabel(formElement, submitter, labels, variant)
    const backdrop = this.allowedValue(
      ALLOWED_BACKDROPS,
      this.dataValue('confirmBackdrop', submitter, formElement),
      labels.defaultBackdrop || 'blur'
    )

    this.dialog.dataset.confirmVariant = variant
    this.dialog.dataset.confirmBackdrop = backdrop
    this.titleElement.textContent = title || ''
    this.messageElement.textContent = String(message || '')
    this.cancelButton.textContent = labels.cancelLabel || ''
    this.cancelButton.setAttribute('aria-label', labels.cancelLabel || '')
    this.confirmButton.textContent = confirmLabel
    this.iconElement.textContent = this.confirmIcon(formElement, submitter, variant)
  }

  confirmVariant (formElement, submitter) {
    const explicitVariant = this.allowedValue(
      ALLOWED_VARIANTS,
      this.dataValue('confirmVariant', submitter, formElement),
      null
    )
    if (explicitVariant) return explicitVariant

    const method = this.formMethod(formElement, submitter)
    if (method === 'delete') return 'danger'

    return 'neutral'
  }

  formMethod (formElement, submitter) {
    const methodOverride = formElement?.querySelector(METHOD_OVERRIDE_SELECTOR)?.value
    const method = submitter?.getAttribute('formmethod') || methodOverride || formElement?.getAttribute('method')
    return String(method || '').toLowerCase()
  }

  confirmTitle (formElement, submitter, labels, variant) {
    const explicitTitle = this.boundedText(this.dataValue('confirmTitle', submitter, formElement), 80)
    if (explicitTitle) return explicitTitle

    return variant === 'danger' ? labels.dangerTitle : labels.defaultTitle
  }

  confirmLabel (formElement, submitter, labels, variant) {
    const explicitLabel = this.boundedText(
      this.dataValue('confirmConfirmLabel', submitter, formElement),
      40
    )
    if (explicitLabel) return explicitLabel

    const submitterLabel = this.submitterLabel(submitter)
    if (submitterLabel) return submitterLabel

    return variant === 'danger'
      ? (labels.dangerConfirmLabel || labels.confirmLabel || '')
      : (labels.confirmLabel || '')
  }

  confirmIcon (formElement, submitter, variant) {
    const explicitIcon = this.allowedValue(
      ALLOWED_ICONS,
      this.dataValue('confirmIcon', submitter, formElement),
      null
    )
    if (explicitIcon) return explicitIcon

    if (variant === 'danger') return 'warning'

    return 'help'
  }

  allowedValue (allowedValues, value, fallback) {
    const normalizedValue = String(value || '').trim()
    return allowedValues.has(normalizedValue) ? normalizedValue : fallback
  }

  boundedText (value, maxLength) {
    const text = String(value || '').trim().replace(/\s+/g, ' ')
    return text.length > 0 && text.length <= maxLength ? text : ''
  }

  dataValue (name, ...elements) {
    for (const element of elements) {
      const value = element?.dataset?.[name]
      if (typeof value === 'string') return value.trim()
    }

    return null
  }

  submitterLabel (submitter) {
    if (!submitter) return ''

    const clone = submitter.cloneNode(true)
    clone.querySelectorAll(MATERIAL_ICON_SELECTOR).forEach((element) => element.remove())
    const label = (clone.value || clone.textContent || submitter.getAttribute('aria-label') || '').trim().replace(/\s+/g, ' ')

    return label.length <= 40 ? label : ''
  }

  focusCancelButton () {
    window.requestAnimationFrame(() => {
      this.cancelButton?.focus()
    })
  }

  focusRestoreTarget (submitter, formElement) {
    return submitter instanceof window.HTMLElement ? submitter : formElement
  }

  handleCancel (event) {
    event.preventDefault()
    this.finish(false)
  }

  handleConfirm (event) {
    event.preventDefault()
    this.finish(true)
  }

  handleNativeCancel (event) {
    event.preventDefault()
    this.finish(false)
  }

  handleClose () {
    if (!this.resolve) this.cleanup()
  }

  handleKeydown (event) {
    if (event.key === 'Escape') {
      event.preventDefault()
      this.finish(false)
      return
    }

    if (event.key !== 'Tab') return

    this.trapFocus(event)
  }

  handleBeforeCache () {
    this.finish(false, { restoreFocus: false })
  }

  trapFocus (event) {
    const focusableElements = this.focusableElements()

    if (focusableElements.length === 0) {
      event.preventDefault()
      this.dialog.focus()
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

  focusableElements () {
    return Array.from(this.dialog.querySelectorAll(FOCUSABLE_SELECTOR)).filter((element) => {
      if (element.hasAttribute('disabled')) return false
      if (element.getAttribute('aria-hidden') === 'true') return false

      const style = window.getComputedStyle(element)
      return style.display !== 'none' && style.visibility !== 'hidden'
    })
  }

  finish (result, { restoreFocus = true } = {}) {
    if (!this.resolve) {
      this.cleanup({ restoreFocus })
      return
    }

    const resolve = this.resolve
    this.resolve = null

    if (this.dialog?.open) this.dialog.close()
    this.cleanup({ restoreFocus })
    resolve(result)
  }

  cleanup ({ restoreFocus = true } = {}) {
    this.unlockBodyScroll()

    if (restoreFocus) this.restoreFocus()

    this.restoreFocusElement = null
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
    if (!this.restoreFocusElement?.isConnected) return

    this.restoreFocusElement.focus()
  }
}

const recifyConfirmDialog = new RecifyConfirmDialog()

if (Turbo?.config?.forms) {
  Turbo.config.forms.confirm = (message, formElement, submitter) => (
    recifyConfirmDialog.confirm(message, formElement, submitter)
  )
}
