import { Controller } from '@hotwired/stimulus'

class PasskeyRequestError extends Error {
  constructor (displayMessage) {
    super('Passkey request failed')
    this.displayMessage = displayMessage
  }
}

export default class extends Controller {
  static targets = ['button', 'error']
  static values = {
    optionsUrl: String,
    createUrl: String,
    unsupportedMessage: String,
    canceledMessage: String,
    failureMessage: String,
    requestFailedMessage: String,
    conditional: Boolean
  }

  connect () {
    this.conditionalAbortController = null
    if (this.conditionalValue) this.startConditionalLogin()
  }

  disconnect () {
    this.abortConditionalLogin()
  }

  async login (event) {
    event.preventDefault()
    this.hideError()
    this.abortConditionalLogin()

    if (!window.PublicKeyCredential || !navigator.credentials?.get) {
      this.showError(this.unsupportedMessageValue)
      return
    }

    this.setLoading(true)

    try {
      const optionsResponse = await this.fetchJson(this.optionsUrlValue, {
        method: 'POST'
      })
      const publicKey = this.decodeRequestOptions(optionsResponse.publicKey)
      const credential = await navigator.credentials.get({ publicKey })

      if (!credential) {
        this.showError(this.failureMessageValue)
        return
      }

      await this.submitCredential(credential)
    } catch (error) {
      this.showError(this.userFacingErrorMessage(error))
    } finally {
      this.setLoading(false)
    }
  }

  async startConditionalLogin () {
    if (!this.supportsConditionalMediation()) return

    let abortController = null

    try {
      const available = await window.PublicKeyCredential.isConditionalMediationAvailable()
      if (!available) return

      this.abortConditionalLogin()
      abortController = new AbortController()
      this.conditionalAbortController = abortController

      const optionsResponse = await this.fetchJson(this.optionsUrlValue, {
        method: 'POST'
      })
      if (abortController.signal.aborted) return

      const publicKey = this.decodeRequestOptions(optionsResponse.publicKey)
      const credential = await navigator.credentials.get({
        publicKey,
        mediation: 'conditional',
        signal: abortController.signal
      })
      if (!credential || abortController.signal.aborted) return

      await this.submitCredential(credential)
    } catch (_error) {
      // Conditional UI should stay quiet; password login and the explicit passkey button remain available.
    } finally {
      if (abortController && this.conditionalAbortController === abortController) {
        this.conditionalAbortController = null
      }
    }
  }

  supportsConditionalMediation () {
    return Boolean(
      window.PublicKeyCredential &&
      typeof window.PublicKeyCredential.isConditionalMediationAvailable === 'function' &&
      navigator.credentials?.get
    )
  }

  abortConditionalLogin () {
    if (!this.conditionalAbortController) return

    this.conditionalAbortController.abort()
    this.conditionalAbortController = null
  }

  async submitCredential (credential) {
    const loginResponse = await this.fetchJson(this.createUrlValue, {
      method: 'POST',
      body: JSON.stringify({
        credential: this.serializeCredential(credential)
      })
    })

    window.location.assign(loginResponse.redirect_url || '/')
  }

  async fetchJson (url, options = {}) {
    const response = await fetch(url, {
      credentials: 'same-origin',
      ...options,
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        ...(options.headers || {})
      }
    })
    const payload = await response.json().catch(() => ({}))

    if (!response.ok) {
      throw new PasskeyRequestError(payload.error || this.requestFailedMessageValue)
    }

    return payload
  }

  userFacingErrorMessage (error) {
    if (error instanceof PasskeyRequestError) {
      return error.displayMessage || this.requestFailedMessageValue
    }

    if (this.browserCredentialErrorNames().includes(error?.name)) {
      return this.failureMessageValue
    }

    return this.failureMessageValue
  }

  browserCredentialErrorNames () {
    return ['NotAllowedError', 'AbortError', 'SecurityError', 'InvalidStateError']
  }

  decodeRequestOptions (publicKey) {
    return {
      ...publicKey,
      challenge: this.base64UrlToArrayBuffer(publicKey.challenge),
      allowCredentials: (publicKey.allowCredentials || []).map((credential) => ({
        ...credential,
        id: this.base64UrlToArrayBuffer(credential.id)
      }))
    }
  }

  serializeCredential (credential) {
    return {
      type: credential.type,
      id: credential.id,
      rawId: this.arrayBufferToBase64Url(credential.rawId),
      authenticatorAttachment: credential.authenticatorAttachment,
      clientExtensionResults: credential.getClientExtensionResults(),
      response: {
        authenticatorData: this.arrayBufferToBase64Url(credential.response.authenticatorData),
        clientDataJSON: this.arrayBufferToBase64Url(credential.response.clientDataJSON),
        signature: this.arrayBufferToBase64Url(credential.response.signature),
        userHandle: credential.response.userHandle ? this.arrayBufferToBase64Url(credential.response.userHandle) : null
      }
    }
  }

  base64UrlToArrayBuffer (value) {
    const base64 = value.replace(/-/g, '+').replace(/_/g, '/')
    const padded = base64.padEnd(base64.length + ((4 - base64.length % 4) % 4), '=')
    const binary = window.atob(padded)
    const bytes = new Uint8Array(binary.length)

    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index)
    }

    return bytes.buffer
  }

  arrayBufferToBase64Url (buffer) {
    const bytes = new Uint8Array(buffer)
    let binary = ''

    bytes.forEach((byte) => {
      binary += String.fromCharCode(byte)
    })

    return window.btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
  }

  setLoading (loading) {
    if (!this.hasButtonTarget) return

    this.buttonTarget.disabled = loading
    this.buttonTarget.classList.toggle('opacity-60', loading)
  }

  showError (message) {
    if (!this.hasErrorTarget) return

    this.errorTarget.textContent = message
    this.errorTarget.classList.remove('hidden')
  }

  hideError () {
    if (!this.hasErrorTarget) return

    this.errorTarget.textContent = ''
    this.errorTarget.classList.add('hidden')
  }
}
