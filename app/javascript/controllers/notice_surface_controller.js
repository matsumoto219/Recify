import { Controller } from '@hotwired/stimulus'

// Connects to data-controller="notice-surface"
export default class extends Controller {
  static values = {
    animation: String,
    autoDismiss: Boolean,
    autoDismissDelay: Number,
    removeBeforeCache: Boolean
  }

  initialize () {
    this.handleBeforeCache = this.handleBeforeCache.bind(this)
  }

  connect () {
    if (this.removeBeforeCacheValue) {
      document.addEventListener('turbo:before-cache', this.handleBeforeCache)
    }

    if (this.element.dataset.noticeInitialized !== 'true') {
      this.element.dataset.noticeInitialized = 'true'

      this.enforceContainerLimit()
      if (!this.element.isConnected) return

      requestAnimationFrame(() => {
        if (this.animationValue === 'slide_right') {
          this.element.classList.remove('opacity-0', 'translate-x-full')
        } else if (this.animationValue === 'slide_down') {
          this.element.classList.remove('opacity-0', '-translate-y-4')
        } else {
          this.element.classList.remove('opacity-0')
        }
      })
    }

    if (this.closing) {
      this.scheduleRemoval()
      return
    }

    this.startAutoDismissTimer()
  }

  close () {
    if (!this.element.isConnected || this.closing) return

    this.clearTimers()
    this.closing = true
    this.element.classList.add('opacity-0', '-translate-y-2')
    this.scheduleRemoval()
  }

  disconnect () {
    if (this.removeBeforeCacheValue) {
      document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
    }

    this.clearTimers()
  }

  handleBeforeCache () {
    this.clearTimers()
    this.element.remove()
  }

  enforceContainerLimit () {
    const container = this.element.closest('[data-notice-surface-container]')
    if (!container) return

    const maxVisible = Number.parseInt(container.dataset.noticeSurfaceMaxVisible || '', 10)
    if (!Number.isInteger(maxVisible) || maxVisible <= 0) return

    const notices = Array.from(container.querySelectorAll('[data-controller~="notice-surface"]')).filter((notice) => (
      notice.closest('[data-notice-surface-container]') === container
    ))
    const excessCount = notices.length - maxVisible
    if (excessCount <= 0) return

    notices.slice(0, excessCount).forEach((notice) => notice.remove())
  }

  startAutoDismissTimer () {
    if (!this.autoDismissValue || this.dismissTimeout || this.removeTimeout) return

    const delay = this.autoDismissDelayValue > 0 ? this.autoDismissDelayValue : 4000
    this.dismissDeadline ||= performance.now() + delay
    const remaining = Math.max(this.dismissDeadline - performance.now(), 0)

    this.dismissTimeout = setTimeout(() => {
      this.dismissTimeout = null
      if (!this.element.isConnected) return

      this.closing = true
      this.element.classList.add('opacity-0', '-translate-y-2')
      this.scheduleRemoval()
    }, remaining)
  }

  scheduleRemoval () {
    if (this.removeTimeout) return

    this.removeTimeout = setTimeout(() => {
      this.removeTimeout = null
      this.element.remove()
    }, 250)
  }

  clearTimers () {
    if (this.dismissTimeout) {
      clearTimeout(this.dismissTimeout)
      this.dismissTimeout = null
    }

    if (this.removeTimeout) {
      clearTimeout(this.removeTimeout)
      this.removeTimeout = null
    }
  }
}
