import { Controller } from '@hotwired/stimulus'

const CLOSED_CLASSES = ['opacity-0', '-translate-y-2']
const CLOSE_DURATION_MS = 200

export default class extends Controller {
  static targets = ['button', 'panel']

  connect () {
    this.handleOutsideClick = this.handleOutsideClick.bind(this)
    this.handleKeydown = this.handleKeydown.bind(this)
    this.closeBeforeCache = this.closeBeforeCache.bind(this)
    this.closeTimer = null
    this.openFrame = null

    this.close({ animated: false })
    document.addEventListener('pointerdown', this.handleOutsideClick)
    document.addEventListener('keydown', this.handleKeydown)
    document.addEventListener('turbo:before-cache', this.closeBeforeCache)
  }

  disconnect () {
    document.removeEventListener('pointerdown', this.handleOutsideClick)
    document.removeEventListener('keydown', this.handleKeydown)
    document.removeEventListener('turbo:before-cache', this.closeBeforeCache)
    this.clearCloseTimer()
    this.cancelOpenFrame()
  }

  toggle (event) {
    event.preventDefault()

    if (this.isOpen()) {
      this.close()
    } else {
      this.open()
    }
  }

  open () {
    const panel = this.panelElement()
    if (!panel) return

    const surface = this.surfaceElement(panel)
    const motion = this.motionElement(panel)
    this.clearCloseTimer()
    this.cancelOpenFrame()
    surface?.classList.remove(...CLOSED_CLASSES)
    panel.classList.remove('hidden')
    this.buttonTarget?.setAttribute('aria-expanded', 'true')

    if (this.prefersReducedMotion()) {
      motion?.classList.remove(...CLOSED_CLASSES)
      return
    }

    this.openFrame = requestAnimationFrame(() => {
      motion?.classList.remove(...CLOSED_CLASSES)
      this.openFrame = null
    })
  }

  close ({ animated = true } = {}) {
    const panel = this.panelElement()
    if (!panel) return

    const surface = this.surfaceElement(panel)
    const motion = this.motionElement(panel)
    this.clearCloseTimer()
    this.cancelOpenFrame()
    this.buttonTarget?.setAttribute('aria-expanded', 'false')

    if (!animated || this.prefersReducedMotion() || panel.classList.contains('hidden')) {
      motion?.classList.add(...CLOSED_CLASSES)
      surface?.classList.remove(...CLOSED_CLASSES)
      panel.classList.add('hidden')
      return
    }

    surface?.classList.add(...CLOSED_CLASSES)

    this.closeTimer = setTimeout(() => {
      motion?.classList.add(...CLOSED_CLASSES)
      surface?.classList.remove(...CLOSED_CLASSES)
      panel.classList.add('hidden')
      this.closeTimer = null
    }, CLOSE_DURATION_MS)
  }

  handleOutsideClick (event) {
    if (!this.isOpen()) return
    if (this.element.contains(event.target)) return
    if (this.panelElement()?.contains(event.target)) return

    this.close()
  }

  handleKeydown (event) {
    if (event.key !== 'Escape') return
    if (!this.isOpen()) return

    this.close()
    this.buttonTarget?.focus()
  }

  closeBeforeCache () {
    this.close({ animated: false })
  }

  isOpen () {
    return this.buttonTarget?.getAttribute('aria-expanded') === 'true'
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

  panelElement () {
    if (this.hasPanelTarget) return this.panelTarget

    const panelId = this.buttonTarget?.getAttribute('aria-controls')
    if (!panelId) return null

    return document.getElementById(panelId)
  }

  motionElement (panel) {
    return panel?.querySelector('[data-notification-dropdown-motion]') || panel
  }

  surfaceElement (panel) {
    return panel?.querySelector('[data-notification-dropdown-surface]') || panel
  }
}
