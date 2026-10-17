import { Controller } from '@hotwired/stimulus'

// Connects to data-controller="receipt-registration"
export default class extends Controller {
  static targets = ['error']

  connect () {
    this.showTransportError = (event) => {
      if (event.target === this.element) this.errorTarget.hidden = false
    }
    this.clearTransportError = () => {
      this.errorTarget.hidden = true
    }
    this.element.addEventListener('turbo:fetch-request-error', this.showTransportError)
    this.element.addEventListener('turbo:submit-start', this.clearTransportError)
    document.addEventListener('turbo:before-cache', this.clearTransportError)
  }

  disconnect () {
    this.element.removeEventListener('turbo:fetch-request-error', this.showTransportError)
    this.element.removeEventListener('turbo:submit-start', this.clearTransportError)
    document.removeEventListener('turbo:before-cache', this.clearTransportError)
  }
}
