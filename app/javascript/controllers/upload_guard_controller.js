import { Controller } from '@hotwired/stimulus'
import { Turbo } from '@hotwired/turbo-rails'

// Connects to data-controller="upload-guard"
export default class extends Controller {
  static values = {
    title: String,
    message: String,
    pendingMessage: String,
    leaveLabel: String,
    stayLabel: String
  }

  connect () {
    this.connection = Symbol('upload-guard')
    this.submitting = false
    this.confirming = false
    this.allowedVisit = null
    this.responseLocation = null
    this.formLocation = new URL(window.location.href)
    this.discardOnCache = false
    this.beforeUnload = this.handleBeforeUnload.bind(this)
    this.beforeVisit = this.handleBeforeVisit.bind(this)
    this.visit = this.handleVisit.bind(this)
    this.beforeCache = this.handleBeforeCache.bind(this)
    this.resetCacheDiscard = () => {
      this.discardOnCache = false
    }
    this.submitStart = () => {
      this.submitting = this.hasSelectedImage()
      this.allowedVisit = null
      this.responseLocation = null
      this.discardOnCache = false
    }
    this.submitEnd = (event) => {
      this.submitting = false
      if (!event.detail.success) this.responseLocation = null
    }
    this.beforeResponse = this.handleBeforeResponse.bind(this)
    this.pageHide = this.discardSelectedImages.bind(this)
    this.pageShow = this.handlePageShow.bind(this)
    window.addEventListener('beforeunload', this.beforeUnload)
    window.addEventListener('pagehide', this.pageHide)
    window.addEventListener('pageshow', this.pageShow)
    document.addEventListener('turbo:before-visit', this.beforeVisit)
    document.addEventListener('turbo:visit', this.visit)
    document.addEventListener('turbo:before-cache', this.beforeCache)
    document.addEventListener('turbo:load', this.resetCacheDiscard)
    document.addEventListener('turbo:fetch-request-error', this.resetCacheDiscard)
    this.element.addEventListener('turbo:submit-start', this.submitStart)
    this.element.addEventListener('turbo:submit-end', this.submitEnd)
    this.element.addEventListener('turbo:before-fetch-response', this.beforeResponse)
  }

  disconnect () {
    this.connection = null
    window.removeEventListener('beforeunload', this.beforeUnload)
    window.removeEventListener('pagehide', this.pageHide)
    window.removeEventListener('pageshow', this.pageShow)
    document.removeEventListener('turbo:before-visit', this.beforeVisit)
    document.removeEventListener('turbo:visit', this.visit)
    document.removeEventListener('turbo:before-cache', this.beforeCache)
    document.removeEventListener('turbo:load', this.resetCacheDiscard)
    document.removeEventListener('turbo:fetch-request-error', this.resetCacheDiscard)
    this.element.removeEventListener('turbo:submit-start', this.submitStart)
    this.element.removeEventListener('turbo:submit-end', this.submitEnd)
    this.element.removeEventListener('turbo:before-fetch-response', this.beforeResponse)
  }

  hasSelectedImage () {
    return Array.from(this.element.elements).some((input) => input.type === 'file' && input.files?.length > 0)
  }

  needsConfirmation () {
    return this.submitting || this.hasSelectedImage()
  }

  discardSelectedImages () {
    Array.from(this.element.elements).forEach((input) => {
      if (input.type === 'file') input.value = ''
    })
    this.element.dispatchEvent(new Event('upload-guard:discard', { bubbles: true }))
  }

  handleBeforeUnload (event) {
    if (!this.needsConfirmation()) return

    event.preventDefault()
    event.returnValue = true
  }

  handleBeforeResponse (event) {
    if (event.target !== this.element || !this.submitting) return

    // Showing this form's response is not confirmation that its upload was accepted.
    this.responseLocation = event.detail.fetchResponse?.location?.href || null
  }

  handleVisit (event) {
    const url = new URL(event.detail.url, window.location.href)
    this.discardOnCache = url.origin !== this.formLocation.origin ||
      url.pathname !== this.formLocation.pathname || url.search !== this.formLocation.search
  }

  handleBeforeCache () {
    if (!this.discardOnCache) return

    this.discardOnCache = false
    this.discardSelectedImages()
  }

  handlePageShow (event) {
    if (!event.persisted) return

    this.submitting = false
    this.allowedVisit = null
    this.responseLocation = null
    this.formLocation = new URL(window.location.href)
    this.discardOnCache = false
  }

  async handleBeforeVisit (event) {
    this.discardOnCache = false
    if (event.defaultPrevented) return

    const url = new URL(event.detail.url, window.location.href)
    if (this.samePageAnchor(url)) return

    const allowedVisit = this.allowedVisit
    const responseLocation = this.responseLocation
    this.allowedVisit = null
    this.responseLocation = null
    if (!this.needsConfirmation() || url.href === allowedVisit || url.href === responseLocation) return

    event.preventDefault()
    if (this.confirming) return

    const confirm = window.RecifyConfirm?.confirm
    if (typeof confirm !== 'function') return

    this.confirming = true
    const connection = this.connection
    try {
      const leave = await confirm(this.submitting ? this.pendingMessageValue : this.messageValue, {
        title: this.titleValue,
        confirmLabel: this.leaveLabelValue,
        cancelLabel: this.stayLabelValue,
        icon: 'warning',
        restoreFocusElement: document.activeElement
      })
      if (!leave || !this.connection || connection !== this.connection || !this.element.isConnected) return

      this.discardSelectedImages()
      this.allowedVisit = url.href
      Turbo.visit(url.href)
    } catch {
      // An unavailable dialog must not silently discard the selected image.
    } finally {
      if (connection === this.connection) this.confirming = false
    }
  }

  samePageAnchor (url) {
    const current = window.location
    return (url.hash || current.hash) && url.origin === current.origin && url.pathname === current.pathname && url.search === current.search
  }
}
