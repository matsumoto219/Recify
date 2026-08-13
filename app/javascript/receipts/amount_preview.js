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

function greatestCommonDivisor (left, right) {
  let a = left < 0n ? -left : left
  let b = right < 0n ? -right : right

  while (b !== 0n) {
    const remainder = a % b
    a = b
    b = remainder
  }

  return a
}

function reducedRatio (numerator, denominator) {
  if (denominator <= 0n) return null

  const divisor = greatestCommonDivisor(numerator, denominator)
  return {
    numerator: numerator / divisor,
    denominator: denominator / divisor
  }
}

function exactUnsignedDecimalRatio (value) {
  let text = String(value ?? '')
    .trim()
    .replace(/[０-９]/g, (character) => String.fromCharCode(character.charCodeAt(0) - 0xFEE0))
    .replace(/＋/g, '+')
    .replace(/－/g, '-')
    .replace(/．/g, '.')
    .replace(/，/g, ',')
  if (text === '') return null

  const commaCount = (text.match(/,/g) || []).length
  if (!text.includes('.') && commaCount === 1) text = text.replace(',', '.')

  const integerComponent = '(?:\\d+|\\d{1,3}(?:,\\d{3})+)'
  const match = text.match(new RegExp(`^(${integerComponent})?(?:\\.(\\d*))?$`))
  if (!match || (!match[1] && !match[2])) return null

  const integerDigits = String(match[1] || '0').replace(/,/g, '')
  const fractionalDigits = String(match[2] || '').replace(/0+$/, '')
  const denominator = 10n ** BigInt(fractionalDigits.length)
  const numerator = BigInt(`${integerDigits}${fractionalDigits}` || '0')

  return {
    ...reducedRatio(numerator, denominator),
    scale: fractionalDigits.length
  }
}

function exactQuantityRatio (value, unit, { maximum, maximumScale }) {
  const ratio = exactUnsignedDecimalRatio(value)
  if (!ratio || ratio.numerator <= 0n || ratio.scale > maximumScale) return null
  if (ratio.numerator * maximum.denominator > maximum.numerator * ratio.denominator) return null
  if ((ratio.numerator * unit.granularityDenominator) %
      (ratio.denominator * unit.granularityNumerator) !== 0n) return null

  return ratio
}

function exactPositiveInteger (value) {
  const text = String(value ?? '')
  if (!/^\d+$/.test(text)) return null

  const integer = BigInt(text)
  return integer > 0n ? integer : null
}

function boundedScale (value) {
  return Number.isInteger(value) && value >= 0 && value <= 18 ? value : null
}

function referencePricingSemantics (contract) {
  if (!contract || typeof contract !== 'object' || !contract.units || typeof contract.units !== 'object') return null

  const priceMaximum = exactUnsignedDecimalRatio(contract.price_amount_max)
  const quantityMaximum = exactUnsignedDecimalRatio(contract.quantity_max)
  const priceMaximumScale = boundedScale(contract.price_amount_max_scale)
  const quantityMaximumScale = boundedScale(contract.quantity_max_scale)
  if (!priceMaximum || !quantityMaximum || priceMaximumScale === null || quantityMaximumScale === null) return null

  const units = Object.fromEntries(Object.entries(contract.units).map(([code, metadata]) => {
    const conversionGroup = typeof metadata?.conversion_group === 'string'
      ? metadata.conversion_group.trim()
      : ''
    const scaleNumerator = exactPositiveInteger(metadata?.scale_numerator)
    const scaleDenominator = exactPositiveInteger(metadata?.scale_denominator)
    const granularityNumerator = exactPositiveInteger(metadata?.granularity_numerator)
    const granularityDenominator = exactPositiveInteger(metadata?.granularity_denominator)
    const allowedPricingRoles = Array.isArray(metadata?.allowed_pricing_roles)
      ? new Set(metadata.allowed_pricing_roles.filter((role) => role === 'purchased' || role === 'reference'))
      : new Set()
    if (!conversionGroup || !scaleNumerator || !scaleDenominator ||
      !granularityNumerator || !granularityDenominator || allowedPricingRoles.size === 0) return [code, null]

    return [code, {
      conversionGroup,
      scaleNumerator,
      scaleDenominator,
      granularityNumerator,
      granularityDenominator,
      allowedPricingRoles
    }]
  }))

  return {
    priceMaximum,
    priceMaximumScale,
    quantityMaximum,
    quantityMaximumScale,
    units
  }
}

function halfUpNonnegativeRatio (numerator, denominator) {
  const quotient = numerator / denominator
  const remainder = numerator % denominator

  return quotient + (remainder * 2n >= denominator ? 1n : 0n)
}

// Mirrors Amounts::ReferenceItemExtension without converting exact source
// decimals to binary floating point. Invalid or incomplete source returns null.
export function referenceItemExtension ({
  referencePricingContract,
  referencePriceAmount,
  referenceQuantity,
  referenceUnitCode,
  purchasedQuantity,
  purchasedUnitCode
}) {
  const semantics = referencePricingSemantics(referencePricingContract)
  if (!semantics) return null

  const referenceUnit = semantics.units[String(referenceUnitCode ?? '')]
  const purchasedUnit = semantics.units[String(purchasedUnitCode ?? '')]
  if (!referenceUnit || !purchasedUnit) return null
  if (!referenceUnit.allowedPricingRoles.has('reference') ||
    !purchasedUnit.allowedPricingRoles.has('purchased')) return null
  if (referenceUnit.conversionGroup !== purchasedUnit.conversionGroup) return null

  const price = exactUnsignedDecimalRatio(referencePriceAmount)
  if (!price || price.scale > semantics.priceMaximumScale) return null
  if (price.numerator * semantics.priceMaximum.denominator >
    semantics.priceMaximum.numerator * price.denominator) return null

  const quantityContract = {
    maximum: semantics.quantityMaximum,
    maximumScale: semantics.quantityMaximumScale
  }
  const reference = exactQuantityRatio(referenceQuantity, referenceUnit, quantityContract)
  const purchased = exactQuantityRatio(purchasedQuantity, purchasedUnit, quantityContract)
  if (!reference || !purchased) return null

  const exact = reducedRatio(
    price.numerator * purchased.numerator * purchasedUnit.scaleNumerator *
      referenceUnit.scaleDenominator * reference.denominator,
    price.denominator * purchased.denominator * purchasedUnit.scaleDenominator *
      reference.numerator * referenceUnit.scaleNumerator
  )
  if (!exact) return null

  const projectedAmount = halfUpNonnegativeRatio(exact.numerator, exact.denominator)
  if (projectedAmount > BigInt(Number.MAX_SAFE_INTEGER)) return null

  return Object.freeze({
    exactNumerator: exact.numerator.toString(),
    exactDenominator: exact.denominator.toString(),
    projectedAmount: Number(projectedAmount)
  })
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
