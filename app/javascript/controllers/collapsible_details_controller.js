import { Controller } from '@hotwired/stimulus'

const CLOSE_DURATION_MS = 220

// Progressive enhancement for native details/summary disclosure cards.
// Without JavaScript, the browser keeps the native details behavior.
export default class extends Controller {
  static targets = ['content']

  connect () {
    this.summary = this.element.querySelector('summary')
    this.handleSummaryClick = this.handleSummaryClick.bind(this)
    this.handleBeforeCache = this.handleBeforeCache.bind(this)
    this.closeTimer = null
    this.openFrame = null

    this.element.dataset.collapsibleEnhanced = 'true'
    this.syncOpenState(this.element.open)
    this.syncContentAvailability(this.element.open)
    this.summary?.addEventListener('click', this.handleSummaryClick)
    document.addEventListener('turbo:before-cache', this.handleBeforeCache)
  }

  disconnect () {
    this.summary?.removeEventListener('click', this.handleSummaryClick)
    document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
    this.clearCloseTimer()
    this.cancelOpenFrame()
  }

  handleSummaryClick (event) {
    event.preventDefault()

    if (this.isOpen()) {
      this.close()
    } else {
      this.open()
    }
  }

  open () {
    this.clearCloseTimer()
    this.cancelOpenFrame()

    this.element.open = true
    this.syncContentAvailability(true)

    if (this.prefersReducedMotion()) {
      this.syncOpenState(true)
      return
    }

    this.element.dataset.collapsibleOpen = 'false'
    this.openFrame = requestAnimationFrame(() => {
      this.syncOpenState(true)
      this.openFrame = null
    })
  }

  close () {
    this.clearCloseTimer()
    this.cancelOpenFrame()
    this.syncOpenState(false)
    this.syncContentAvailability(false)

    if (this.prefersReducedMotion()) {
      this.element.open = false
      return
    }

    this.closeTimer = setTimeout(() => {
      this.element.open = false
      this.closeTimer = null
    }, CLOSE_DURATION_MS)
  }

  handleBeforeCache () {
    this.clearCloseTimer()
    this.cancelOpenFrame()

    if (this.isOpen()) {
      this.element.open = true
      this.syncOpenState(true)
      this.syncContentAvailability(true)
    } else {
      this.element.open = false
      this.syncOpenState(false)
      this.syncContentAvailability(false)
    }
  }

  isOpen () {
    return this.element.dataset.collapsibleOpen === 'true' || (this.element.open && this.element.dataset.collapsibleOpen !== 'false')
  }

  syncOpenState (open) {
    this.element.dataset.collapsibleOpen = String(open)
  }

  syncContentAvailability (available) {
    if (!this.hasContentTarget) return

    this.contentTarget.toggleAttribute('inert', !available)
    this.contentTarget.setAttribute('aria-hidden', String(!available))
  }

  clearCloseTimer () {
    if (!this.closeTimer) return

    clearTimeout(this.closeTimer)
    this.closeTimer = null
  }

  cancelOpenFrame () {
    if (this.openFrame === null) return

    cancelAnimationFrame(this.openFrame)
    this.openFrame = null
  }

  prefersReducedMotion () {
    return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }
}
