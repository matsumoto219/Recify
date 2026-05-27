import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['source', 'status']
  static values = {
    successMessage: String,
    failureMessage: String
  }

  async copy() {
    const text = this.sourceText()

    try {
      await navigator.clipboard.writeText(text)
      this.showStatus(this.successMessageValue)
    } catch (_error) {
      this.showStatus(this.failureMessageValue)
    }
  }

  sourceText() {
    if (!this.hasSourceTarget) return ''

    return (this.sourceTarget.value || this.sourceTarget.textContent || '').trim()
  }

  showStatus(message) {
    if (!this.hasStatusTarget) return

    this.statusTarget.textContent = message
    this.statusTarget.classList.remove('hidden')
  }
}
