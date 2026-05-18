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
    if (!this.hasPanelTarget) return

    this.panelTarget.classList.remove('hidden')
    this.buttonTarget?.setAttribute('aria-expanded', 'true')
  }

  close () {
    if (!this.hasPanelTarget) return

    this.panelTarget.classList.add('hidden')
    this.buttonTarget?.setAttribute('aria-expanded', 'false')
  }

  handleOutsideClick (event) {
    if (!this.isOpen()) return
    if (this.element.contains(event.target)) return

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
    return this.hasPanelTarget && !this.panelTarget.classList.contains('hidden')
  }
}
