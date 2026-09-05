const MIN_FRAME_DIMENSION = 100
const MAX_FRAME_DIMENSION = 10000
const MAX_CAPTURE_BYTES = 20 * 1024 * 1024

class CameraCaptureError extends Error {
  constructor (reason) {
    super(reason)
    this.reason = reason
  }
}

function stopStream (stream) {
  stream?.getTracks().forEach((track) => track.stop())
}

function validDimensions (width, height) {
  return [width, height].every((value) => Number.isInteger(value) && value >= MIN_FRAME_DIMENSION && value <= MAX_FRAME_DIMENSION)
}

function cropBounds (video, guide) {
  const viewport = video.getBoundingClientRect()
  const validBounds = [viewport, guide].every((bounds) => bounds &&
    [bounds.left, bounds.top, bounds.width, bounds.height].every(Number.isFinite) && bounds.width > 0 && bounds.height > 0)
  if (!validBounds) throw new CameraCaptureError('capture')

  const scale = Math.min(viewport.width / video.videoWidth, viewport.height / video.videoHeight)
  const renderedLeft = viewport.left + (viewport.width - video.videoWidth * scale) / 2
  const renderedTop = viewport.top + (viewport.height - video.videoHeight * scale) / 2
  const left = (guide.left - renderedLeft) / scale
  const top = (guide.top - renderedTop) / scale
  const right = (guide.left + guide.width - renderedLeft) / scale
  const bottom = (guide.top + guide.height - renderedTop) / scale
  if (![left, top, right, bottom].every(Number.isFinite) || left < 0 || top < 0 || right > video.videoWidth || bottom > video.videoHeight) {
    throw new CameraCaptureError('capture')
  }

  const x = Math.ceil(left)
  const y = Math.ceil(top)
  const width = Math.floor(right) - x
  const height = Math.floor(bottom) - y
  if (!validDimensions(width, height)) throw new CameraCaptureError('capture')

  return { x, y, width, height }
}

export function supportsInlineCamera ({ secureContext, mediaDevices, finePointer }) {
  return secureContext === true && finePointer === true && typeof mediaDevices?.getUserMedia === 'function'
}

export class CameraCapture {
  constructor ({ mediaDevices = navigator.mediaDevices, createCanvas = () => document.createElement('canvas') } = {}) {
    this.mediaDevices = mediaDevices
    this.createCanvas = createCanvas
    this.generation = 0
    this.stream = null
  }

  async start (deviceId) {
    this.stop()
    const generation = this.generation

    try {
      const video = deviceId ? { deviceId: { exact: deviceId } } : true
      const stream = await this.mediaDevices.getUserMedia({ video, audio: false })
      if (generation !== this.generation) {
        stopStream(stream)
        return null
      }
      if (!stream.getVideoTracks().some((track) => track.readyState === 'live')) {
        stopStream(stream)
        throw new CameraCaptureError('unavailable')
      }

      this.stream = stream
      return stream
    } catch (error) {
      if (generation !== this.generation) return null

      const reason = ['NotAllowedError', 'SecurityError'].includes(error?.name) ? 'permission' : 'unavailable'
      throw new CameraCaptureError(reason)
    }
  }

  async devices () {
    if (!this.stream) return []

    try {
      const devices = await this.mediaDevices.enumerateDevices()
      const seen = new Set()
      return devices.filter((device) => {
        if (device.kind !== 'videoinput' || !device.deviceId || seen.has(device.deviceId)) return false

        seen.add(device.deviceId)
        return true
      })
    } catch {
      return []
    }
  }

  async capture (video, guideBounds) {
    let canvas
    try {
      if (!this.stream || ![2, 3, 4].includes(video.readyState) || !validDimensions(video.videoWidth, video.videoHeight)) throw new CameraCaptureError('capture')

      const { x, y, width, height } = cropBounds(video, guideBounds)
      canvas = this.createCanvas()
      canvas.width = width
      canvas.height = height
      canvas.getContext('2d').drawImage(video, x, y, width, height, 0, 0, width, height)
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', 0.95))
      if (!blob || blob.type !== 'image/jpeg' || blob.size === 0 || blob.size > MAX_CAPTURE_BYTES) {
        throw new CameraCaptureError('capture')
      }

      return blob
    } catch {
      throw new CameraCaptureError('capture')
    } finally {
      if (canvas) {
        canvas.width = 0
        canvas.height = 0
      }
    }
  }

  stop () {
    this.generation += 1
    stopStream(this.stream)
    this.stream = null
  }
}
