export function normalizeRoundingMode (value) {
  return ['floor', 'ceil', 'round'].includes(value) ? value : 'floor'
}

export function applyRounding (value, roundingMode) {
  switch (normalizeRoundingMode(roundingMode)) {
    case 'ceil':
      return Math.ceil(value)
    case 'round':
      return value < 0 ? -Math.round(Math.abs(value)) : Math.round(value)
    default:
      return Math.floor(value)
  }
}

export function roundLineAmount (value) {
  return Math.round(value)
}

export function clampNumber (value, min, max) {
  if (!Number.isFinite(value)) return min
  return Math.min(Math.max(value, min), max)
}

export function formatNumber (num) {
  return Math.floor(num).toLocaleString()
}

export function easeOutCubic (progress) {
  return 1 - Math.pow(1 - progress, 3)
}

export function formatTaxRate (taxRate) {
  return Number.isInteger(taxRate) ? String(taxRate) : String(taxRate).replace(/\.0+$/, '')
}

export function formatSignedAmount (value) {
  const amount = Math.floor(Math.abs(value))
  const sign = value < 0 ? '-' : '+'

  return `${sign}¥${formatNumber(amount)}`
}

export function formatPaymentDifference (value) {
  if (value === 0) return `¥${formatNumber(0)}`

  return formatSignedAmount(value)
}

export function externalTaxTotal (taxGroups, roundingMode) {
  let taxTotal = 0

  taxGroups.forEach((groupLineTotal, taxRatePercent) => {
    taxTotal += applyRounding((groupLineTotal * taxRatePercent) / 100, roundingMode)
  })

  return taxTotal
}

export function internalTaxTotal (taxGroups, roundingMode) {
  let taxTotal = 0

  taxGroups.forEach((groupLineTotal, taxRatePercent) => {
    taxTotal += applyRounding((groupLineTotal * taxRatePercent) / (100 + taxRatePercent), roundingMode)
  })

  return taxTotal
}

export function discountedLineTotal (originalLineTotal, discountRatePercent, roundingMode) {
  if (discountRatePercent === null) return originalLineTotal

  const discountAmount = applyRounding((originalLineTotal * discountRatePercent) / 100, roundingMode)
  return Math.max(originalLineTotal - discountAmount, 0)
}

export function formatTaxRateSummary (taxRates, { unsetLabel, multipleTaxRatesLabel }) {
  if (taxRates.size === 0) return unsetLabel
  if (taxRates.size > 1) return multipleTaxRatesLabel

  const [taxRate] = Array.from(taxRates)
  return `${formatTaxRate(taxRate)}%`
}
