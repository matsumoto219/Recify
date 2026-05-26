import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['button', 'error']
  static values = {
    optionsUrl: String,
    createUrl: String,
    unsupportedMessage: String,
    canceledMessage: String,
    failureMessage: String,
    requestFailedMessage: String
  }

  async login (event) {
    event.preventDefault()
    this.hideError()

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
        this.showError(this.canceledMessageValue)
        return
      }

      const loginResponse = await this.fetchJson(this.createUrlValue, {
        method: 'POST',
        body: JSON.stringify({
          credential: this.serializeCredential(credential)
        })
      })

      window.location.assign(loginResponse.redirect_url || '/')
    } catch (error) {
      this.showError(error.message || this.failureMessageValue)
    } finally {
      this.setLoading(false)
    }
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
      throw new Error(payload.error || this.requestFailedMessageValue)
    }

    return payload
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
