import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['source', 'status']
  static values = {
    successMessage: String,
    failureMessage: String
  }

  connect () {
    this.statusTimeout = null
    this.boundHideStatus = this.hideStatus.bind(this)
    this.listeningForViewportChanges = false
    this.floatingStatusElement = null
  }

  disconnect () {
    this.clearStatusTimeout()
    this.removeFloatingStatusElement()
    this.removeViewportListeners()
  }

  async copy (event) {
    const text = this.sourceText()
    const trigger = event?.currentTarget

    if (!text) {
      this.showStatus(this.failureMessageValue, trigger)
      return
    }

    try {
      await navigator.clipboard.writeText(text)
      this.showStatus(this.successMessageValue, trigger)
    } catch (_error) {
      this.showStatus(this.failureMessageValue, trigger)
    }
  }

  sourceText () {
    if (!this.hasSourceTarget) return ''

    return (this.sourceTarget.value || this.sourceTarget.textContent || '').trim()
  }

  showStatus (message, trigger) {
    if (!this.hasStatusTarget) return

    this.clearStatusTimeout()
    this.statusTarget.textContent = message

    if (this.usesFloatingStatus()) {
      this.statusTarget.classList.add('hidden')
      this.showFloatingStatus(message)
      this.positionFloatingStatus(trigger)
      this.addViewportListeners()
    } else {
      this.statusTarget.classList.remove('hidden')
      this.statusTarget.removeAttribute('style')
    }

    this.statusTimeout = window.setTimeout(() => {
      this.hideStatus()
    }, 2200)
  }

  hideStatus () {
    if (!this.hasStatusTarget) return

    this.clearStatusTimeout()
    this.statusTarget.classList.add('hidden')

    if (this.usesFloatingStatus()) {
      this.removeFloatingStatusElement()
      this.removeViewportListeners()
    }
  }

  usesFloatingStatus () {
    return this.hasStatusTarget && this.statusTarget.dataset.clipboardFloatingStatus === 'true'
  }

  positionFloatingStatus (trigger) {
    const statusElement = this.floatingStatusElement || this.statusTarget

    if (!trigger || !statusElement) return

    const margin = 8
    const triggerRect = trigger.getBoundingClientRect()

    statusElement.style.left = '0px'
    statusElement.style.top = '0px'
    statusElement.style.visibility = 'hidden'

    const tooltipRect = statusElement.getBoundingClientRect()
    const centeredLeft = triggerRect.left + ((triggerRect.width - tooltipRect.width) / 2)
    const centeredTop = triggerRect.top + ((triggerRect.height - tooltipRect.height) / 2)
    const placements = [
      { top: triggerRect.top - tooltipRect.height - margin, left: centeredLeft },
      { top: triggerRect.bottom + margin, left: centeredLeft },
      { top: centeredTop, left: triggerRect.left - tooltipRect.width - margin },
      { top: centeredTop, left: triggerRect.right + margin }
    ]

    const position = placements.find((placement) => (
      placement.left >= margin &&
      placement.top >= margin &&
      placement.left + tooltipRect.width <= window.innerWidth - margin &&
      placement.top + tooltipRect.height <= window.innerHeight - margin
    )) || placements[0]

    const clampedLeft = this.clamp(position.left, margin, window.innerWidth - tooltipRect.width - margin)
    const clampedTop = this.clamp(position.top, margin, window.innerHeight - tooltipRect.height - margin)

    statusElement.style.left = `${Math.round(clampedLeft)}px`
    statusElement.style.top = `${Math.round(clampedTop)}px`
    statusElement.style.visibility = 'visible'
  }

  clamp (value, min, max) {
    if (max < min) return min

    return Math.min(Math.max(value, min), max)
  }

  clearStatusTimeout () {
    if (!this.statusTimeout) return

    window.clearTimeout(this.statusTimeout)
    this.statusTimeout = null
  }

  addViewportListeners () {
    if (this.listeningForViewportChanges) return

    window.addEventListener('resize', this.boundHideStatus)
    window.addEventListener('scroll', this.boundHideStatus, true)
    this.listeningForViewportChanges = true
  }

  removeViewportListeners () {
    if (!this.listeningForViewportChanges) return

    window.removeEventListener('resize', this.boundHideStatus)
    window.removeEventListener('scroll', this.boundHideStatus, true)
    this.listeningForViewportChanges = false
  }

  showFloatingStatus (message) {
    if (!this.floatingStatusElement) {
      this.floatingStatusElement = document.createElement('span')
      this.floatingStatusElement.className = this.statusTarget.className
      this.floatingStatusElement.classList.remove('hidden')
      this.floatingStatusElement.removeAttribute('data-clipboard-target')
      this.floatingStatusElement.removeAttribute('data-clipboard-floating-status')
      this.floatingStatusElement.setAttribute('aria-live', this.statusTarget.getAttribute('aria-live') || 'polite')
      this.floatingStatusElement.setAttribute('role', this.statusTarget.getAttribute('role') || 'status')
      document.body.appendChild(this.floatingStatusElement)
    }

    this.floatingStatusElement.textContent = message
    this.floatingStatusElement.classList.remove('hidden')
  }

  removeFloatingStatusElement () {
    if (!this.floatingStatusElement) return

    this.floatingStatusElement.remove()
    this.floatingStatusElement = null
  }
}
