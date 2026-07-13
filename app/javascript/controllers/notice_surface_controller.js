import { Controller } from '@hotwired/stimulus'

// Connects to data-controller="notice-surface"
export default class extends Controller {
  static values = {
    animation: String,
    autoDismiss: Boolean,
    autoDismissDelay: Number,
    removeBeforeCache: Boolean
  }

  connect () {
    this.handleBeforeCache = this.handleBeforeCache.bind(this)

    if (this.removeBeforeCacheValue) {
      document.addEventListener('turbo:before-cache', this.handleBeforeCache)
    }

    if (this.element.dataset.noticeInitialized === 'true') return
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

    if (this.autoDismissValue) {
      const timeout = this.autoDismissDelayValue > 0 ? this.autoDismissDelayValue : 4000

      this.dismissTimeout = setTimeout(() => {
        if (!this.element.isConnected) return
        this.element.classList.add('opacity-0', '-translate-y-2')
        this.removeTimeout = setTimeout(() => this.element.remove(), 250)
      }, timeout)
    }
  }

  close () {
    if (!this.element.isConnected) return

    this.clearTimers()
    this.element.classList.add('opacity-0', '-translate-y-2')
    this.removeTimeout = setTimeout(() => this.element.remove(), 250)
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
    const container = this.element.parentElement
    if (!container?.matches('[data-notice-surface-container]')) return

    const maxVisible = Number.parseInt(container.dataset.noticeSurfaceMaxVisible || '', 10)
    if (!Number.isInteger(maxVisible) || maxVisible <= 0) return

    const notices = Array.from(container.children).filter((child) => (
      child.matches('[data-controller~="notice-surface"]')
    ))
    const excessCount = notices.length - maxVisible
    if (excessCount <= 0) return

    notices.slice(0, excessCount).forEach((notice) => notice.remove())
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
