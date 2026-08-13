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
    const step = this.parseStepperValue(input.step || '1') || this.parseStepperValue('1')
    const currentValue = this.parseStepperValue(input.value) || this.parseStepperValue('0')
    const nextValue = this.clampValue(this.addValue(currentValue, step, delta), input)

    input.value = this.formatValue(nextValue, step.scale)
    input.dispatchEvent(new Event('input', { bubbles: true }))
    input.dispatchEvent(new Event('change', { bubbles: true }))
  }

  clampValue (value, input) {
    const min = input.min === '' ? null : this.parseStepperValue(input.min)
    const max = input.max === '' ? null : this.parseStepperValue(input.max)

    if (min !== null && this.compareValues(value, min) < 0) return min
    if (max !== null && this.compareValues(value, max) > 0) return max

    return value
  }

  addValue (value, step, delta) {
    const scale = Math.max(value.scale, step.scale)

    return {
      units: this.unitsAtScale(value, scale) + (this.unitsAtScale(step, scale) * BigInt(delta)),
      scale
    }
  }

  compareValues (left, right) {
    const scale = Math.max(left.scale, right.scale)
    const leftUnits = this.unitsAtScale(left, scale)
    const rightUnits = this.unitsAtScale(right, scale)

    if (leftUnits < rightUnits) return -1
    if (leftUnits > rightUnits) return 1
    return 0
  }

  unitsAtScale (value, scale) {
    return value.units * (10n ** BigInt(scale - value.scale))
  }

  formatValue (value, stepScale) {
    const precision = this.hasDecimalPrecisionValue ? this.decimalPrecisionValue : stepScale
    const roundedUnits = this.roundUnits(value, precision)
    const negative = roundedUnits < 0n
    const digits = (negative ? -roundedUnits : roundedUnits).toString().padStart(precision + 1, '0')
    const integerDigits = precision > 0 ? digits.slice(0, -precision) : digits
    const fractionalDigits = precision > 0 ? digits.slice(-precision).replace(/0+$/, '') : ''
    const formatted = fractionalDigits === '' ? integerDigits : `${integerDigits}.${fractionalDigits}`

    return negative && formatted !== '0' ? `-${formatted}` : formatted
  }

  roundUnits (value, precision) {
    if (value.scale <= precision) return this.unitsAtScale(value, precision)

    const divisor = 10n ** BigInt(value.scale - precision)
    const quotient = value.units / divisor
    const remainder = value.units % divisor
    if (remainder === 0n) return quotient

    const absoluteRemainder = remainder < 0n ? -remainder : remainder
    if (absoluteRemainder * 2n < divisor) return quotient

    return quotient + (value.units < 0n ? -1n : 1n)
  }

  parseStepperValue (value) {
    const text = String(value ?? '').trim()
    if (text.length > 64) return null
    if (!/^-?(?:\d+(?:\.\d*)?|\.\d+)$/.test(text)) return null

    const negative = text.startsWith('-')
    const unsignedText = negative ? text.slice(1) : text
    const [integerDigits = '0', fractionalDigits = ''] = unsignedText.split('.')
    const units = BigInt(`${integerDigits || '0'}${fractionalDigits}` || '0')

    return {
      units: negative ? -units : units,
      scale: fractionalDigits.length
    }
  }
}
