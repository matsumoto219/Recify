import { Controller } from '@hotwired/stimulus'

const TURNSTILE_SCRIPT_ID = 'cloudflare-turnstile-api'
const TURNSTILE_SCRIPT_SRC = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit'

let turnstileLoadPromise

const loadTurnstile = () => {
  if (window.turnstile?.render) return Promise.resolve(window.turnstile)

  if (turnstileLoadPromise) return turnstileLoadPromise

  turnstileLoadPromise = new Promise((resolve, reject) => {
    const existingScript = document.getElementById(TURNSTILE_SCRIPT_ID)

    if (existingScript) {
      existingScript.addEventListener('load', () => resolve(window.turnstile), { once: true })
      existingScript.addEventListener('error', reject, { once: true })
      return
    }

    const script = document.createElement('script')
    script.id = TURNSTILE_SCRIPT_ID
    script.src = TURNSTILE_SCRIPT_SRC
    script.async = true
    script.defer = true
    script.addEventListener('load', () => resolve(window.turnstile), { once: true })
    script.addEventListener('error', reject, { once: true })

    document.head.appendChild(script)
  })

  return turnstileLoadPromise
}

export default class extends Controller {
  static values = {
    siteKey: String
  }

  connect () {
    this.widgetId = null
    this.boundBeforeCache = this.removeWidget.bind(this)

    document.addEventListener('turbo:before-cache', this.boundBeforeCache)
    this.renderWidget()
  }

  disconnect () {
    document.removeEventListener('turbo:before-cache', this.boundBeforeCache)
    this.removeWidget()
  }

  renderWidget () {
    if (!this.hasSiteKeyValue || this.widgetId !== null) return

    loadTurnstile()
      .then((turnstile) => {
        if (!this.element.isConnected || this.widgetId !== null || !turnstile?.render) return

        this.widgetId = turnstile.render(this.element, {
          sitekey: this.siteKeyValue,
          callback: () => {},
          'expired-callback': () => this.resetWidget(),
          'error-callback': () => this.resetWidget()
        })
      })
      .catch(() => {})
  }

  resetWidget () {
    if (this.widgetId === null || !window.turnstile?.reset) return

    window.turnstile.reset(this.widgetId)
  }

  removeWidget () {
    if (this.widgetId === null) return

    if (window.turnstile?.remove) {
      window.turnstile.remove(this.widgetId)
    }

    this.widgetId = null
  }
}
