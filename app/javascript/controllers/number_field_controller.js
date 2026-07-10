import { Controller } from '@hotwired/stimulus'

// Connects to data-controller="number-field"
export default class extends Controller {
  static targets = ['input']
  static values = {
    decimalPrecision: Number
  }

  connect () {
    this.repeatTimeoutId = null
    this.repeatIntervalId = null
    this.accelerationTimeoutIds = []
    this.currentDelta = null
  }

  disconnect () {
    this.stopChanging()
  }

  startIncrementing (event) {
    this.startChanging(event, 1)
  }

  startDecrementing (event) {
    this.startChanging(event, -1)
  }

  startChanging (event, delta) {
    event.preventDefault()

    this.stopChanging()
    this.currentDelta = delta
    this.changeValue(delta)

    this.repeatTimeoutId = window.setTimeout(() => {
      // 1段目
      this.startRepeat(delta, 120)

      // 2段目
      this.accelerationTimeoutIds.push(
        window.setTimeout(() => {
          this.startRepeat(delta, 60)
        }, 1500)
      )

      // 3段目
      this.accelerationTimeoutIds.push(
        window.setTimeout(() => {
          this.startRepeat(delta, 35)
        }, 3000)
      )

      // 4段目（かなり長押し時のみ）
      this.accelerationTimeoutIds.push(
        window.setTimeout(() => {
          this.startRepeat(delta, 10)
        }, 5000)
      )
    }, 350)
  }

  startRepeat (delta, intervalMs) {
    if (this.currentDelta !== delta) return

    if (this.repeatIntervalId) {
      window.clearInterval(this.repeatIntervalId)
    }

    this.repeatIntervalId = window.setInterval(() => {
      this.changeValue(delta)
    }, intervalMs)
  }

  stopChanging () {
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

  changeValue (delta) {
    if (!this.hasInputTarget) return

    const input = this.inputTarget
    const step = Number.parseFloat(input.step || '1') || 1
    const currentValue = this.parseStepperValue(input.value) ?? 0
    const nextValue = this.clampValue(currentValue + (step * delta), input)

    input.value = this.formatValue(nextValue, step)
    input.dispatchEvent(new Event('input', { bubbles: true }))
    input.dispatchEvent(new Event('change', { bubbles: true }))
  }

  clampValue (value, input) {
    const min = input.min === '' ? null : Number.parseFloat(input.min)
    const max = input.max === '' ? null : Number.parseFloat(input.max)

    if (min !== null && !Number.isNaN(min) && value < min) return min
    if (max !== null && !Number.isNaN(max) && value > max) return max

    return value
  }

  formatValue (value, step) {
    if (Number.isInteger(step) && !this.hasDecimalPrecisionValue) {
      return String(Math.round(value))
    }

    const precision = this.hasDecimalPrecisionValue ? this.decimalPrecisionValue : this.decimalPrecision(step)
    const multiplier = 10 ** precision
    const roundedValue = Math.round((value + Number.EPSILON) * multiplier) / multiplier

    if (precision > 0) {
      return String(roundedValue).replace(/\.0+$/, '').replace(/(\.\d*?)0+$/, '$1')
    }

    return String(Math.round(roundedValue))
  }

  decimalPrecision (value) {
    const valueText = String(value)
    const decimalPart = valueText.split('.')[1]

    return decimalPart ? decimalPart.length : 0
  }

  parseStepperValue (value) {
    const text = String(value ?? '').trim()
    if (!/^-?(?:\d+(?:\.\d*)?|\.\d+)$/.test(text)) return null

    const parsedValue = Number.parseFloat(text)
    return Number.isFinite(parsedValue) ? parsedValue : null
  }
}
