const MIME_ALIASES = {
  'image/jpg': 'image/jpeg',
  'image/pjpeg': 'image/jpeg',
  'image/x-png': 'image/png',
  'image/x-bmp': 'image/bmp',
  'image/x-ms-bmp': 'image/bmp',
  'image/x-tiff': 'image/tiff'
}

const EXTENSION_TYPES = {
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  png: 'image/png',
  bmp: 'image/bmp',
  tif: 'image/tiff',
  tiff: 'image/tiff',
  heif: 'image/heif',
  heic: 'image/heic',
  webp: 'image/webp'
}

export function isAllowedImageFile (file, allowedTypes) {
  if (!file || (file.type != null && typeof file.type !== 'string')) return false

  const type = file.type?.toLowerCase() || ''
  if (type && type !== 'application/octet-stream') return allowedTypes.includes(MIME_ALIASES[type] || type)

  // Browser metadata only filters selections; the server validates the original image bytes.
  const name = file.name
  if (typeof name !== 'string' || /[/\\]/.test(name)) return false
  if (Array.from(name).some((character) => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127)) return false

  const extension = name.match(/^.+\.(jpe?g|png|bmp|tiff?|heif|heic|webp)$/i)?.[1].toLowerCase()
  return allowedTypes.includes(EXTENSION_TYPES[extension])
}
