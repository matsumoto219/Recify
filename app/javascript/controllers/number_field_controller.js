import { Controller } from '@hotwired/stimulus'

// Connects to data-controller="number-field"
export default class extends Controller {
  static targets = ['input']
  static values = {
    decimalPrecision: Number,
    decimalComma: { type: Boolean, default: false }
  }

  connect () {
    this.repeatTimeoutId = null
    this.repeatIntervalId = null
    this.accelerationTimeoutIds = []
    this.currentDelta = null
    this.isComposing = false
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
    const currentValue = Number.parseFloat(this.sanitizeNumericValue(input.value) || '0') || 0
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

  startComposition () {
    this.isComposing = true
  }

  finishComposition (event) {
    this.isComposing = false
    this.normalize(event)

    const input = event.target
    const numericValue = Number.parseFloat(this.sanitizeNumericValue(input.value))
    if (!Number.isNaN(numericValue)) {
      input.value = this.formatValue(
        this.clampValue(numericValue, input),
        Number.parseFloat(input.step || '1') || 1
      )
    }
  }

  normalize (event) {
    const input = event.target
    if (this.isComposing || event.isComposing) return
    const originalValue = input.value

    let value = this.sanitizeNumericValue(input.value)

    if (value !== '' && value !== '-' && value !== '.' && value !== '-.') {
      const isEditingDecimal = value.endsWith('.') || value === '-.'

      if (!isEditingDecimal) {
        const numericValue = Number.parseFloat(value)
        if (!Number.isNaN(numericValue)) {
          value = String(this.clampValue(numericValue, input))
        }
      }
    }

    if (value !== originalValue) {
      input.value = value
      input.dispatchEvent(new Event('input', { bubbles: true }))
    }
  }

  sanitizeNumericValue (inputValue) {
    // 全角数字 → 半角
    let value = String(inputValue || '').replace(/[０-９]/g, (s) =>
      String.fromCharCode(s.charCodeAt(0) - 0xFEE0)
    )

    // 全角小数点・マイナス・カンマ対応
    value = value
      .replace(/．/g, '.')
      .replace(/－/g, '-')
      .replace(/，/g, ',')

    value = this.normalizeComma(value)

    // 数字・小数点・マイナス以外を除去
    value = value.replace(/[^0-9.-]/g, '')

    // マイナスは先頭のみ許可
    value = value.replace(/(?!^)-/g, '')

    // 小数点は1つだけ許可
    const parts = value.split('.')
    if (parts.length > 2) {
      value = parts[0] + '.' + parts.slice(1).join('')
    }

    return value
  }

  normalizeComma (value) {
    if (!this.decimalCommaValue) {
      return value.replace(/,/g, '')
    }

    const commaCount = (value.match(/,/g) || []).length
    if (!value.includes('.') && commaCount === 1) {
      return value.replace(',', '.')
    }

    return value.replace(/,/g, '')
  }
}
