import { Controller } from '@hotwired/stimulus'

// Connects to data-controller="image-load-state"
export default class extends Controller {
  static targets = ['image', 'fallback']
  static values = {
    fallbackWhileLoading: { type: Boolean, default: false }
  }

  connect () {
    this.state = null
    this.sync()

    queueMicrotask(() => {
      if (this.element.isConnected) this.sync()
    })
  }

  imageLoaded (event) {
    if (!this.currentImageEvent(event)) return

    if (this.imageTarget.naturalWidth > 0) {
      this.showAvailable()
    } else {
      this.showUnavailable()
    }
  }

  imageFailed (event) {
    if (!this.currentImageEvent(event)) return

    this.showUnavailable()
  }

  beforeCache () {
    this.state = null

    if (!this.hasImageTarget) return

    const hasSource = this.imageTarget.getAttribute('src')?.length > 0
    this.imageTarget.classList.add('hidden')

    if (this.hasFallbackTarget) {
      this.fallbackTarget.classList.toggle('hidden', hasSource && !this.fallbackWhileLoadingValue)
    }

    this.element.setAttribute('aria-busy', String(hasSource))
  }

  sync () {
    if (!this.hasImageTarget) return

    const source = this.imageTarget.getAttribute('src')
    if (!source) {
      this.showUnavailable()
      return
    }

    if (!this.imageTarget.complete) {
      this.element.setAttribute('aria-busy', 'true')
      return
    }

    if (this.imageTarget.naturalWidth > 0) {
      this.showAvailable()
    } else {
      this.showUnavailable()
    }
  }

  showAvailable () {
    this.imageTarget.classList.remove('hidden')
    if (this.hasFallbackTarget) this.fallbackTarget.classList.add('hidden')
    this.element.setAttribute('aria-busy', 'false')
    this.dispatchState('available')
  }

  showUnavailable () {
    if (this.hasImageTarget) this.imageTarget.classList.add('hidden')
    if (this.hasFallbackTarget) this.fallbackTarget.classList.remove('hidden')
    this.element.setAttribute('aria-busy', 'false')
    this.dispatchState('unavailable')
  }

  dispatchState (state) {
    if (this.state === state) return

    this.state = state
    this.dispatch(state)
  }

  currentImageEvent (event) {
    return !event?.currentTarget || event.currentTarget === this.imageTarget
  }
}
