export function normalizedOptionalDecimalInput (value) {
  const rawValue = trimNumericInputText(value)
  if (rawValue === '') return ''

  return String(parseDecimalInput(rawValue))
}

export function quantityUnitList (value) {
  return String(value ?? '')
    .split(',')
    .map((unit) => unit.trim())
    .filter((unit) => unit !== '')
}

export function decimalSeparatorText (value) {
  return /[.,．，]/.test(String(value ?? ''))
}

export function hasDecimalSeparator (value) {
  return decimalSeparatorText(value)
}

export function decimalFractionIsZero (value) {
  const normalized = normalizeQuantityText(value)
  const decimalPart = normalized.split(/[.,]/)[1]

  return decimalPart === undefined || /^0*$/.test(decimalPart.replace(/[^0-9]/g, ''))
}

export function integerQuantityText (value) {
  const normalized = normalizeQuantityText(value)
  const integerPart = normalized.split(/[.,]/)[0]

  return integerPart
    .replace(/[^0-9-]/g, '')
    .replace(/(?!^)-/g, '')
}

export function normalizeQuantityText (value) {
  return String(value ?? '')
    .replace(/[０-９]/g, (character) => String.fromCharCode(character.charCodeAt(0) - 0xFEE0))
    .replace(/．/g, '.')
    .replace(/，/g, ',')
    .replace(/－/g, '-')
}

export function parseIntegerInput (value) {
  const normalized = normalizeNumericInputText(value)
  if (!/^(?:\d+|\d{1,3}(?:,\d{3})+)$/.test(normalized)) return Number.NaN

  const parsedValue = Number(normalized.replace(/,/g, ''))
  return Number.isSafeInteger(parsedValue) ? parsedValue : Number.NaN
}

export function parseDecimalInput (value) {
  return parseDecimalInputWithOptions(value, { decimalComma: true })
}

export function parseGroupedDecimalInput (value) {
  return parseDecimalInputWithOptions(value, { decimalComma: false })
}

export function parseQuantityInput (value) {
  const parsedValue = parseDecimalInput(value)
  const scale = decimalInputScale(value, { decimalComma: true })
  if (!Number.isFinite(parsedValue) || scale === null || scale > 3) return Number.NaN

  return parsedValue
}

function parseDecimalInputWithOptions (value, { decimalComma }) {
  let normalized = normalizeNumericInputText(value)

  const commaCount = (normalized.match(/,/g) || []).length
  if (decimalComma && !normalized.includes('.') && commaCount === 1) {
    normalized = normalized.replace(',', '.')
  }

  const integerComponent = '(?:\\d+|\\d{1,3}(?:,\\d{3})+)'
  const decimalPattern = new RegExp(`^(?:${integerComponent}(?:\\.\\d*)?|\\.\\d+)$`)
  if (!decimalPattern.test(normalized)) return Number.NaN

  const parsedValue = Number(normalized.replace(/,/g, ''))
  return Number.isFinite(parsedValue) ? parsedValue : Number.NaN
}

export function normalizeNumericInputText (value) {
  return trimNumericInputText(value)
    .replace(/[０-９]/g, (character) => String.fromCharCode(character.charCodeAt(0) - 0xFEE0))
    .replace(/＋/g, '+')
    .replace(/－/g, '-')
    .replace(/．/g, '.')
    .replace(/，/g, ',')
}

export function trimNumericInputText (value) {
  const text = String(value ?? '')
  let start = 0
  let finish = text.length
  while (start < finish && rubyStripCodePoint(text.charCodeAt(start))) start += 1
  while (finish > start && rubyStripCodePoint(text.charCodeAt(finish - 1))) finish -= 1

  return text.slice(start, finish)
}

function rubyStripCodePoint (codePoint) {
  return codePoint === 0 || codePoint === 32 || (codePoint >= 9 && codePoint <= 13)
}

function decimalInputScale (value, { decimalComma }) {
  let normalized = normalizeNumericInputText(value)
  const commaCount = (normalized.match(/,/g) || []).length
  if (decimalComma && !normalized.includes('.') && commaCount === 1) {
    normalized = normalized.replace(',', '.')
  }

  const integerComponent = '(?:\\d+|\\d{1,3}(?:,\\d{3})+)'
  const match = normalized.match(new RegExp(`^(?:${integerComponent})?(?:\\.(\\d*))?$`))
  if (!match || (!normalized.includes('.') && normalized === '')) return null

  return String(match[1] || '').replace(/0+$/, '').length
}

const TAX_RATE_MAX_SCALE = 4
const DISCOUNT_RATE_MAX_SCALE = 3

function percentageRateScale (value) {
  let normalized = normalizeNumericInputText(value)
  const commaCount = (normalized.match(/,/g) || []).length
  if (!normalized.includes('.') && commaCount === 1) normalized = normalized.replace(',', '.')

  const integerComponent = '(?:\\d+|\\d{1,3}(?:,\\d{3})+)'
  const match = normalized.match(new RegExp(`^(${integerComponent})?(?:\\.(\\d*))?$`))
  if (!match || (!match[1] && !match[2])) return null

  const integerDigits = String(match[1] || '0').replace(/,/g, '')
  const fractionalDigits = String(match[2] || '')
  const digits = `${integerDigits}${fractionalDigits}`
  if (/^0+$/.test(digits)) return 0

  const trailingZeroCount = digits.match(/0+$/)?.[0].length || 0
  return Math.max(fractionalDigits.length + 2 - trailingZeroCount, 0)
}

function parsePercentageInput (value, maximumRateScale) {
  const rawValue = trimNumericInputText(value)
  if (rawValue === '') return null

  const parsedValue = parseDecimalInput(rawValue)
  const rateScale = percentageRateScale(rawValue)
  if (!Number.isFinite(parsedValue) || parsedValue > 100 || rateScale === null || rateScale > maximumRateScale) {
    return Number.NaN
  }

  return parsedValue
}

export function parseTaxRateInput (value) {
  return parsePercentageInput(value, TAX_RATE_MAX_SCALE)
}

export function parseDiscountRateInput (value) {
  return parsePercentageInput(value, DISCOUNT_RATE_MAX_SCALE)
}

export function previewValueInRange (value, { minimum, maximum, exclusiveMinimum = false }) {
  if (value === null) return true
  if (!Number.isFinite(value)) return false
  if (exclusiveMinimum ? value <= minimum : value < minimum) return false

  return value <= maximum
}
