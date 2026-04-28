import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="number-field"
export default class extends Controller {
  static targets = ["input"]

  connect() {
    this.repeatTimeoutId = null
    this.repeatIntervalId = null
    this.accelerationTimeoutIds = []
    this.currentDelta = null
  }

  disconnect() {
    this.stopChanging()
  }

  increment() {
    this.changeValue(1)
  }

  decrement() {
    this.changeValue(-1)
  }

  startIncrementing(event) {
    this.startChanging(event, 1)
  }

  startDecrementing(event) {
    this.startChanging(event, -1)
  }

  startChanging(event, delta) {
    event.preventDefault()

    this.stopChanging()
    this.currentDelta = delta
    this.changeValue(delta)

    this.repeatTimeoutId = window.setTimeout(() => {
      this.startRepeat(delta, 120)

      this.accelerationTimeoutIds.push(
        window.setTimeout(() => {
          this.startRepeat(delta, 60)
        }, 1500)
      )

      this.accelerationTimeoutIds.push(
        window.setTimeout(() => {
          this.startRepeat(delta, 10)
        }, 3000)
      )
    }, 350)
  }

  startRepeat(delta, intervalMs) {
    if (this.currentDelta !== delta) return

    if (this.repeatIntervalId) {
      window.clearInterval(this.repeatIntervalId)
    }

    this.repeatIntervalId = window.setInterval(() => {
      this.changeValue(delta)
    }, intervalMs)
  }

  stopChanging() {
    if (this.repeatTimeoutId) {
      window.clearTimeout(this.repeatTimeoutId)
      this.repeatTimeoutId = null
    }

    if (this.repeatIntervalId) {
      window.clearInterval(this.repeatIntervalId)
      this.repeatIntervalId = null
    }

    this.accelerationTimeoutIds.forEach((timeoutId) => {
      window.clearTimeout(timeoutId)
    })
    this.accelerationTimeoutIds = []
    this.currentDelta = null
  }

  changeValue(delta) {
    if (!this.hasInputTarget) return

    const input = this.inputTarget
    const step = Number.parseFloat(input.step || "1") || 1
    const min = input.min === "" ? null : Number.parseFloat(input.min)
    const max = input.max === "" ? null : Number.parseFloat(input.max)
    const currentValue = Number.parseFloat(input.value || "0") || 0
    let nextValue = currentValue + (step * delta)

    if (min !== null && nextValue < min) nextValue = min
    if (max !== null && nextValue > max) nextValue = max

    input.value = this.formatValue(nextValue, step)
    input.dispatchEvent(new Event("input", { bubbles: true }))
    input.dispatchEvent(new Event("change", { bubbles: true }))
  }

  formatValue(value, step) {
    if (Number.isInteger(step)) {
      return String(Math.round(value))
    }

    return String(value)
  }
}
