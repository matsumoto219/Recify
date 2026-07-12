import { Controller } from '@hotwired/stimulus'

// Controls the sliding indicator position for shared/ui/form/segmented_control.
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
    this.committedValue = this.checkedInput()?.value
  }

  update (event) {
    const selectedInput = event.currentTarget
    const index = this.inputTargets.indexOf(selectedInput)

    if (index < 0) return

    this.setActiveIndex(index)
    return this.submitIfRemote(selectedInput.value)
  }

  syncActiveIndex () {
    const checkedInput = this.checkedInput()
    const index = this.inputTargets.indexOf(checkedInput)

    this.setActiveIndex(index >= 0 ? index : 0)
  }

  setActiveIndex (index) {
    this.element.style.setProperty('--segmented-active-index', index)
  }

  checkedInput () {
    return this.inputTargets.find((input) => input.checked)
  }

  submitIfRemote (value) {
    if (!this.remoteValue) {
      this.committedValue = value
      return
    }
    if (!this.hasUrlValue || !this.hasNameValue) return

    return this.submit(value, this.committedValue)
  }

  async submit (value, previousValue) {
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

      const responseBody = await response.text()

      if (responseBody.trim() !== '' && window.Turbo) {
        window.Turbo.renderStreamMessage(responseBody)
      }

      if (!response.ok) {
        this.restoreSelection(previousValue)
        this.dispatchFailure(value, previousValue, response.status)
        return
      }

      this.committedValue = value

      this.dispatch('success', {
        detail: {
          name: this.nameValue,
          value,
          previousValue
        },
        bubbles: true
      })
    } catch (_error) {
      this.restoreSelection(previousValue)
      this.dispatchFailure(value, previousValue, null)
    }
  }

  restoreSelection (value) {
    this.inputTargets.forEach((input) => {
      input.checked = input.value === value
    })
    this.syncActiveIndex()
  }

  dispatchFailure (value, previousValue, status) {
    this.dispatch('failure', {
      detail: {
        name: this.nameValue,
        value,
        previousValue,
        status
      },
      bubbles: true
    })
  }
}
