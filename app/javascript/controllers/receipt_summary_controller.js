import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['label', 'value', 'subtext', 'summaryValue']
  static values = {
    storageKey: String,
    monthlyLabel: String,
    overallLabel: String,
    changeLabel: String,
    countSuffix: String
  }

  connect () {
    const stored = sessionStorage.getItem(this.storageKeyValue)
    this.isMonthly = stored !== 'overall'
    this.render()
    this.animateSummaryValues()
  }

  toggle () {
    if (!this.hasLabelTarget || !this.hasValueTarget || !this.hasSubtextTarget) return

    this.isMonthly = !this.isMonthly

    sessionStorage.setItem(
      this.storageKeyValue,
      this.isMonthly ? 'monthly' : 'overall'
    )

    this.render()
  }

  render () {
    if (!this.hasLabelTarget || !this.hasValueTarget || !this.hasSubtextTarget) return

    if (this.isMonthly) {
      this.labelTarget.innerText = this.monthlyLabel()
      this.valueTarget.innerText = this.formatCurrency(this.currentMonthRawValue())
      this.updateSubtext(
        this.subtextTarget.dataset.monthlyText,
        this.subtextTarget.dataset.monthlyIcon,
        this.subtextTarget.dataset.monthlyIconClass
      )
    } else {
      this.labelTarget.innerText = this.overallLabel()
      this.valueTarget.innerText = this.formatCurrency(this.overallRawValue())
      this.updateSubtext(
        this.subtextTarget.dataset.overallText,
        this.subtextTarget.dataset.overallIcon,
        this.subtextTarget.dataset.overallIconClass
      )
    }
  }

  updateSubtext (text, icon, iconClass) {
    let iconElement = this.subtextTarget.querySelector('.material-symbols-outlined')
    let textElement = Array.from(this.subtextTarget.querySelectorAll('span'))
      .find((element) => !element.classList.contains('material-symbols-outlined'))

    if (icon) {
      if (!iconElement) {
        iconElement = document.createElement('span')
        iconElement.classList.add('material-symbols-outlined')
        iconElement.style.fontSize = '11px'
        iconElement.style.lineHeight = '1'
        this.subtextTarget.prepend(iconElement)
      }

      this.applyIconClass(iconElement, iconClass)
      iconElement.innerText = icon
      iconElement.classList.remove('hidden')
    } else if (iconElement) {
      iconElement.remove()
    }

    if (!textElement) {
      textElement = document.createElement('span')
      this.subtextTarget.append(textElement)
    }

    this.updateSubtextText(textElement, text, icon)
  }

  updateSubtextText (textElement, text, icon) {
    const changeRate = this.extractChangeRate(text)

    if (!icon || !Number.isFinite(changeRate)) {
      textElement.innerText = text
      return
    }

    const storageKey = `${this.storageKeyValue}:monthly_change_rate`
    const previousRate = Number(sessionStorage.getItem(storageKey))

    sessionStorage.setItem(storageKey, String(changeRate))

    if (!Number.isFinite(previousRate) || previousRate === changeRate) {
      textElement.innerText = this.formatChangeRate(changeRate)
      return
    }

    this.animateChangeRate(textElement, previousRate, changeRate)
  }

  extractChangeRate (text) {
    const changeLabel = this.changeLabel()
    if (!changeLabel) return NaN

    const pattern = new RegExp(`${this.escapeRegExp(changeLabel)}\\s*([+\\-±]?)(\\d+)%`)
    const match = text.match(pattern)
    if (!match) return NaN

    const sign = match[1]
    const value = Number(match[2])

    if (!Number.isFinite(value)) return NaN
    if (sign === '-') return -value

    return value
  }

  prefersReducedMotion () {
    return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }

  durationForNumber (element, from, to) {
    const diff = Math.abs((to || 0) - (from || 0))

    if (element === this.valueTarget) {
      return Math.min(900, Math.max(650, 300 + Math.log10(diff + 1) * 120))
    }

    if ((element.dataset.suffix || '') === this.countSuffix()) {
      return Math.min(700, Math.max(350, 250 + Math.log10(diff + 1) * 100))
    }

    return 500
  }

  durationForChangeRate (from, to) {
    const diff = Math.abs((to || 0) - (from || 0))
    return Math.min(800, Math.max(450, 300 + Math.log10(diff + 1) * 120))
  }

  formatChangeRate (value) {
    const changeLabel = this.changeLabel()

    if (value > 0) return `${changeLabel} +${value}%`
    if (value < 0) return `${changeLabel} ${value}%`

    return `${changeLabel} ±0%`
  }

  monthlyLabel () {
    return this.monthlyLabelValue || this.labelTarget?.innerText || ''
  }

  overallLabel () {
    return this.overallLabelValue || this.labelTarget?.innerText || ''
  }

  changeLabel () {
    return this.changeLabelValue || ''
  }

  countSuffix () {
    return this.countSuffixValue || ''
  }

  escapeRegExp (value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  }

  applyIconClass (iconElement, iconClass) {
    Array.from(iconElement.classList)
      .filter((className) =>
        [
          'token-text-muted',
          'token-text-brand',
          'token-text-error'
        ].includes(className)
      )
      .forEach((className) => iconElement.classList.remove(className))

    ;(iconClass || 'token-text-muted')
      .split(/\s+/)
      .filter(Boolean)
      .forEach((className) => iconElement.classList.add(className))
  }

  animateSummaryValues () {
    this.summaryValueTargets.forEach((element) => {
      const key = element.dataset.summaryKey || 'amount'
      const nextValue = this.rawValueFor(element)

      if (!Number.isFinite(nextValue)) return

      const storageKey = `${this.storageKeyValue}:${key}`
      const previousValue = Number(sessionStorage.getItem(storageKey))

      sessionStorage.setItem(storageKey, String(nextValue))

      if (!Number.isFinite(previousValue) || previousValue === nextValue) {
        element.innerText = this.formatValue(element, nextValue)
        return
      }

      this.animateNumber(element, previousValue, nextValue)
    })
  }

  animateNumber (element, from, to) {
    if (this.prefersReducedMotion()) {
      element.innerText = this.formatValue(element, to)
      return
    }

    const duration = this.durationForNumber(element, from, to)
    const startedAt = performance.now()

    if (element._rafId) cancelAnimationFrame(element._rafId)

    const tick = (currentTime) => {
      const progress = Math.min((currentTime - startedAt) / duration, 1)
      const easedProgress = 1 - Math.pow(1 - progress, 3)
      const currentValue = Math.round(from + (to - from) * easedProgress)

      element.innerText = this.formatValue(element, currentValue)

      if (progress < 1) {
        element._rafId = requestAnimationFrame(tick)
      } else {
        element.innerText = this.formatValue(element, to)
        element._rafId = null
      }
    }

    element._rafId = requestAnimationFrame(tick)
  }

  animateChangeRate (element, from, to) {
    if (this.prefersReducedMotion()) {
      element.innerText = this.formatChangeRate(to)
      return
    }

    const duration = this.durationForChangeRate(from, to)
    const startedAt = performance.now()

    if (element._rafId) cancelAnimationFrame(element._rafId)

    const tick = (currentTime) => {
      const progress = Math.min((currentTime - startedAt) / duration, 1)
      const easedProgress = 1 - Math.pow(1 - progress, 3)
      const currentValue = Math.round(from + (to - from) * easedProgress)

      element.innerText = this.formatChangeRate(currentValue)

      if (progress < 1) {
        element._rafId = requestAnimationFrame(tick)
      } else {
        element.innerText = this.formatChangeRate(to)
        element._rafId = null
      }
    }

    element._rafId = requestAnimationFrame(tick)
  }

  rawValueFor (element) {
    if (element === this.valueTarget) {
      return this.isMonthly ? this.currentMonthRawValue() : this.overallRawValue()
    }

    return Number(element.dataset.rawValue)
  }

  currentMonthRawValue () {
    return Number(this.valueTarget.dataset.currentMonthRawValue)
  }

  overallRawValue () {
    return Number(this.valueTarget.dataset.overallRawValue)
  }

  formatValue (element, value) {
    const prefix = element.dataset.prefix || ''
    const suffix = element.dataset.suffix || ''

    return `${prefix}${this.formatNumber(value)}${suffix}`
  }

  formatCurrency (value) {
    return `¥${this.formatNumber(value)}`
  }

  formatNumber (value) {
    return new Intl.NumberFormat('ja-JP').format(value)
  }
}
