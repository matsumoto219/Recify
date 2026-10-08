import { Controller } from '@hotwired/stimulus'

// Connects to data-controller="image-load-state"
export default class extends Controller {
  static targets = ['image', 'fallback', 'empty']
  static values = {
    fallbackWhileLoading: { type: Boolean, default: false }
  }

  connect () {
    this.state = null
    this.connected = true
    this.sync()

    queueMicrotask(() => {
      if (this.connected && this.element.isConnected) this.sync()
    })
  }

  disconnect () {
    this.connected = false
  }

  imageLoaded (event) {
    if (this.currentImageEvent(event)) this.sync()
  }

  imageFailed (event) {
    if (this.currentImageEvent(event)) this.sync()
  }

  beforeCache () {
    // Turbo can prepare a snapshot while this same document remains visible.
    this.sync()
  }

  sync () {
    const image = this.hasImageTarget ? this.imageTarget : null
    const source = image?.getAttribute('src') || ''
    let state = 'empty'

    if (source) {
      state = image.complete ? (image.naturalWidth > 0 ? 'available' : 'unavailable') : 'loading'
    }

    if (image) image.classList.toggle('hidden', state !== 'available')
    if (this.hasFallbackTarget) {
      const showFallback = state === 'unavailable' ||
        (state === 'empty' && !this.hasEmptyTarget) ||
        (state === 'loading' && this.fallbackWhileLoadingValue)
      this.fallbackTarget.classList.toggle('hidden', !showFallback)
    }
    if (this.hasEmptyTarget) this.emptyTarget.classList.toggle('hidden', state !== 'empty')
    this.element.setAttribute('aria-busy', String(state === 'loading'))
    this.element.setAttribute('data-image-load-state-state', state)

    if (this.state !== state || this.source !== source || this.image !== image) {
      this.state = state
      this.source = source
      this.image = image
      this.dispatch(state, { detail: { image, state } })
    }

    return state
  }

  currentImageEvent (event) {
    return this.hasImageTarget && (!event?.currentTarget || event.currentTarget === this.imageTarget)
  }
}
