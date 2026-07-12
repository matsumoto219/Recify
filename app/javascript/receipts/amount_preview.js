export function normalizeRoundingMode (value) {
  return ['floor', 'ceil', 'round'].includes(value) ? value : 'floor'
}

export function applyRounding (value, roundingMode) {
  switch (normalizeRoundingMode(roundingMode)) {
    case 'ceil':
      return Math.ceil(value)
    case 'round':
      return Math.round(value)
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
