import { Controller } from '@hotwired/stimulus'

class PasskeyRequestError extends Error {
  constructor (displayMessage) {
    super('Passkey request failed')
    this.displayMessage = displayMessage
  }
}

export default class extends Controller {
  static targets = ['button', 'label', 'error', 'success']
  static values = {
    optionsUrl: String,
    createUrl: String,
    unsupportedMessage: String,
    canceledMessage: String,
    successMessage: String,
    failureMessage: String,
    requestFailedMessage: String
  }

  async register (event) {
    event.preventDefault()
    this.hideMessages()

    if (!window.PublicKeyCredential || !navigator.credentials?.create) {
      this.showError(this.unsupportedMessageValue)
      return
    }

    this.setLoading(true)

    try {
      const optionsResponse = await this.fetchJson(this.optionsUrlValue, {
        method: 'POST'
      })
      const publicKey = this.decodeCreationOptions(optionsResponse.publicKey)
      const credential = await navigator.credentials.create({ publicKey })

      if (!credential) {
        this.showError(this.failureMessageValue)
        return
      }

      await this.fetchJson(this.createUrlValue, {
        method: 'POST',
        body: JSON.stringify({
          label: this.labelTarget.value,
          credential: this.serializeCredential(credential)
        })
      })

      this.showSuccess(this.successMessageValue)
      window.location.reload()
    } catch (error) {
      this.showError(this.userFacingErrorMessage(error))
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

  decodeCreationOptions (publicKey) {
    return {
      ...publicKey,
      challenge: this.base64UrlToArrayBuffer(publicKey.challenge),
      user: {
        ...publicKey.user,
        id: this.base64UrlToArrayBuffer(publicKey.user.id)
      },
      excludeCredentials: (publicKey.excludeCredentials || []).map((credential) => ({
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
        attestationObject: this.arrayBufferToBase64Url(credential.response.attestationObject),
        clientDataJSON: this.arrayBufferToBase64Url(credential.response.clientDataJSON),
        transports: credential.response.getTransports?.() || []
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

  showSuccess (message) {
    if (!this.hasSuccessTarget) return

    this.successTarget.textContent = message
    this.successTarget.classList.remove('hidden')
  }

  hideMessages () {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = ''
      this.errorTarget.classList.add('hidden')
    }

    if (this.hasSuccessTarget) {
      this.successTarget.textContent = ''
      this.successTarget.classList.add('hidden')
    }
  }
}
