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

// Percentage inputs are decimal source values. Keep them as exact ratios so
// binary floating-point error cannot cross a Ruby BigDecimal rounding boundary.
function decimalRatio (value) {
  const match = String(value).toLowerCase().match(/^([+-]?)(\d+)(?:\.(\d+))?(?:e([+-]?\d+))?$/)
  if (!match) return { numerator: 0n, denominator: 1n }

  const sign = match[1] === '-' ? -1n : 1n
  const fractionalDigits = match[3] || ''
  const exponent = Number.parseInt(match[4] || '0', 10)
  const digits = `${match[2]}${fractionalDigits}`.replace(/^0+(?=\d)/, '')
  const scale = fractionalDigits.length - exponent
  let numerator = BigInt(digits || '0') * sign
  let denominator = 1n

  if (scale > 0) {
    denominator = 10n ** BigInt(scale)
  } else if (scale < 0) {
    numerator *= 10n ** BigInt(-scale)
  }

  return { numerator, denominator }
}

function roundedRatio (numerator, denominator, roundingMode) {
  const negative = numerator < 0n
  const magnitude = negative ? -numerator : numerator
  const quotient = magnitude / denominator
  const remainder = magnitude % denominator
  let rounded = quotient

  switch (normalizeRoundingMode(roundingMode)) {
    case 'ceil':
      if (!negative && remainder > 0n) rounded += 1n
      break
    case 'round':
      if (remainder * 2n >= denominator) rounded += 1n
      break
    default:
      if (negative && remainder > 0n) rounded += 1n
  }

  return Number(negative ? -rounded : rounded)
}

function roundedPercentageAmount (amount, percentage, roundingMode, taxIncluded = false) {
  const percentageRatio = decimalRatio(percentage)
  const numerator = BigInt(amount) * percentageRatio.numerator
  const denominator = taxIncluded
    ? (100n * percentageRatio.denominator) + percentageRatio.numerator
    : 100n * percentageRatio.denominator

  return roundedRatio(numerator, denominator, roundingMode)
}

export function externalTaxTotal (taxGroups, roundingMode) {
  let taxTotal = 0

  taxGroups.forEach((groupLineTotal, taxRatePercent) => {
    taxTotal += roundedPercentageAmount(groupLineTotal, taxRatePercent, roundingMode)
  })

  return taxTotal
}

export function internalTaxTotal (taxGroups, roundingMode) {
  let taxTotal = 0

  taxGroups.forEach((groupLineTotal, taxRatePercent) => {
    taxTotal += roundedPercentageAmount(groupLineTotal, taxRatePercent, roundingMode, true)
  })

  return taxTotal
}

export function discountedLineTotal (originalLineTotal, discountRatePercent, roundingMode) {
  if (discountRatePercent === null) return originalLineTotal

  const discountAmount = roundedPercentageAmount(originalLineTotal, discountRatePercent, roundingMode)
  return Math.max(originalLineTotal - discountAmount, 0)
}

export function formatTaxRateSummary (taxRates, { unsetLabel, multipleTaxRatesLabel }) {
  if (taxRates.size === 0) return unsetLabel
  if (taxRates.size > 1) return multipleTaxRatesLabel

  const [taxRate] = Array.from(taxRates)
  return `${formatTaxRate(taxRate)}%`
}
