export function normalizedOptionalDecimalInput (value) {
  const rawValue = String(value ?? '').trim()
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
  let normalized = normalizeNumericInputText(value)

  const commaCount = (normalized.match(/,/g) || []).length
  if (!normalized.includes('.') && commaCount === 1) {
    normalized = normalized.replace(',', '.')
  }

  const integerComponent = '(?:\\d+|\\d{1,3}(?:,\\d{3})+)'
  const decimalPattern = new RegExp(`^(?:${integerComponent}(?:\\.\\d*)?|\\.\\d+)$`)
  if (!decimalPattern.test(normalized)) return Number.NaN

  const parsedValue = Number(normalized.replace(/,/g, ''))
  return Number.isFinite(parsedValue) ? parsedValue : Number.NaN
}

export function normalizeNumericInputText (value) {
  return String(value ?? '')
    .trim()
    .replace(/[０-９]/g, (character) => String.fromCharCode(character.charCodeAt(0) - 0xFEE0))
    .replace(/＋/g, '+')
    .replace(/－/g, '-')
    .replace(/．/g, '.')
    .replace(/，/g, ',')
}

export function parseDiscountRateInput (value) {
  const rawValue = String(value ?? '').trim()
  if (rawValue === '') return null

  return parseDecimalInput(rawValue)
}

export function previewValueInRange (value, { minimum, maximum, exclusiveMinimum = false }) {
  if (value === null) return true
  if (!Number.isFinite(value)) return false
  if (exclusiveMinimum ? value <= minimum : value < minimum) return false

  return value <= maximum
}
