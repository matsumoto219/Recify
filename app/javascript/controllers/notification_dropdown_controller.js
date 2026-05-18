import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['button', 'panel']

  connect () {
    this.handleOutsideClick = this.handleOutsideClick.bind(this)
    this.handleKeydown = this.handleKeydown.bind(this)
    this.closeBeforeCache = this.closeBeforeCache.bind(this)

    this.close()
    document.addEventListener('pointerdown', this.handleOutsideClick)
    document.addEventListener('keydown', this.handleKeydown)
    document.addEventListener('turbo:before-cache', this.closeBeforeCache)
  }

  disconnect () {
    document.removeEventListener('pointerdown', this.handleOutsideClick)
    document.removeEventListener('keydown', this.handleKeydown)
    document.removeEventListener('turbo:before-cache', this.closeBeforeCache)
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

    panel.classList.remove('hidden')
    this.buttonTarget?.setAttribute('aria-expanded', 'true')
  }

  close () {
    const panel = this.panelElement()
    if (!panel) return

    panel.classList.add('hidden')
    this.buttonTarget?.setAttribute('aria-expanded', 'false')
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
    this.close()
  }

  isOpen () {
    const panel = this.panelElement()

    return Boolean(panel && !panel.classList.contains('hidden'))
  }

  panelElement () {
    if (this.hasPanelTarget) return this.panelTarget

    const panelId = this.buttonTarget?.getAttribute('aria-controls')
    if (!panelId) return null

    return document.getElementById(panelId)
  }
}
