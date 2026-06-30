import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['input', 'button', 'icon']
  static values = {
    showLabel: String,
    hideLabel: String
  }

  connect () {
    this.handleBeforeCache = this.reset.bind(this)
    document.addEventListener('turbo:before-cache', this.handleBeforeCache)
    this.reset()
  }

  disconnect () {
    document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
    this.reset()
  }

  toggle (event) {
    if (!this.hasInputTarget) return

    this.setRevealed(this.inputTarget.type !== 'text')
    this.restoreInputFocusForPointerActivation(event)
  }

  preserveInputFocus (event) {
    if (!this.hasInputTarget || !event.cancelable) return

    event.preventDefault()
  }

  reset () {
    if (!this.hasInputTarget) return

    this.setRevealed(false)
  }

  setRevealed (revealed) {
    if (!this.hasInputTarget) return

    this.inputTarget.type = revealed ? 'text' : 'password'

    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute('aria-pressed', String(revealed))
      this.buttonTarget.setAttribute('aria-label', revealed ? this.hideLabelValue : this.showLabelValue)
    }

    if (this.hasIconTarget) {
      if (this.iconTarget.dataset.animated === 'true') {
        this.iconTarget.dataset.revealed = String(revealed)
      } else {
        this.iconTarget.textContent = revealed ? 'visibility_off' : 'visibility'
      }
    }
  }

  restoreInputFocusForPointerActivation (event) {
    if (!event || event.type !== 'click' || event.detail === 0) return

    try {
      this.inputTarget.focus({ preventScroll: true })
    } catch (_error) {
      this.inputTarget.focus()
    }
  }
}
