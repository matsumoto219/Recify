import { Controller } from '@hotwired/stimulus'

// Controls the sliding indicator position for shared/ui/segmented_control.
// Optionally sends the selected value to a remote endpoint when remoteValue is true.
export default class extends Controller {
  static targets = ['input']

  static values = {
    remote: Boolean,
    url: String,
    method: { type: String, default: 'PATCH' },
    name: String
  }

  connect () {
    this.syncActiveIndex()
  }

  update (event) {
    const selectedInput = event.currentTarget
    const index = this.inputTargets.indexOf(selectedInput)

    if (index < 0) return

    this.setActiveIndex(index)
    this.submitIfRemote(selectedInput.value)
  }

  syncActiveIndex () {
    const checkedInput = this.inputTargets.find((input) => input.checked)
    const index = this.inputTargets.indexOf(checkedInput)

    this.setActiveIndex(index >= 0 ? index : 0)
  }

  setActiveIndex (index) {
    this.element.style.setProperty('--segmented-active-index', index)
  }

  submitIfRemote (value) {
    if (!this.remoteValue) return
    if (!this.hasUrlValue || !this.hasNameValue) return

    this.submit(value)
  }

  async submit (value) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    try {
      const response = await fetch(this.urlValue, {
        method: this.methodValue.toUpperCase(),
        headers: {
          'Content-Type': 'application/json',
          Accept: 'text/vnd.turbo-stream.html',
          ...(csrfToken ? { 'X-CSRF-Token': csrfToken } : {})
        },
        body: JSON.stringify({
          user: {
            [this.nameValue]: value
          }
        })
      })

      if (!response.ok) {
        throw new Error(`Request failed with status ${response.status}`)
      }

      const responseBody = await response.text()

      if (responseBody.trim() !== '') {
        Turbo.renderStreamMessage(responseBody)
      }

      this.dispatch('success', {
        detail: {
          name: this.nameValue,
          value
        },
        bubbles: true
      })
    } catch (error) {
      console.error('[SegmentedControl] Failed to update setting:', error)
    }
  }
}
