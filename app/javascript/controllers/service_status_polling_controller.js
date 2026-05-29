import { Controller } from '@hotwired/stimulus'

// Connects to data-controller="service-status-polling"
export default class extends Controller {
  static targets = [
    'serviceNotice',
    'uploadRoot',
    'uploadControl',
    'uploadSubmit',
    'ocrGatedLink',
    'serviceBadge',
    'serviceStatusCard'
  ]

  static values = {
    statusUrl: String,
    interval: { type: Number, default: 30000 }
  }

  connect () {
    this.pollTimer = null
    this.abortController = null
    this.startPolling()
  }

  disconnect () {
    this.stopPolling()
  }

  startPolling () {
    if (!this.hasStatusUrlValue) return

    this.pollTimer = window.setInterval(() => {
      this.poll()
    }, this.intervalValue)
  }

  stopPolling () {
    if (this.pollTimer) {
      window.clearInterval(this.pollTimer)
      this.pollTimer = null
    }

    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
  }

  async poll () {
    if (document.hidden || !this.hasStatusUrlValue) return

    if (this.abortController) {
      this.abortController.abort()
    }

    const controller = new AbortController()
    this.abortController = controller

    try {
      const response = await fetch(this.statusUrlValue, {
        headers: {
          Accept: 'application/json'
        },
        credentials: 'same-origin',
        signal: controller.signal
      })

      if (!response.ok) return

      const payload = await response.json()
      this.applyPayload(payload)
    } catch (error) {
      if (error.name === 'AbortError') return
    } finally {
      if (this.abortController === controller) {
        this.abortController = null
      }
    }
  }

  pollNow (event) {
    if (event) event.preventDefault()
    this.poll()
  }

  applyPayload (payload) {
    const uploadAllowed = payload?.upload?.allowed !== false

    this.updateServiceStatusCard(payload)
    this.updateNotices(payload?.notices || {})
    this.updateUploadAvailability(uploadAllowed)
    this.updateOcrGatedLinks(uploadAllowed)
    this.updateServiceBadges(payload)
  }

  updateServiceStatusCard (payload) {
    const html = payload?.html
    if (!html) return

    this.serviceStatusCardTargets.forEach((container) => {
      container.innerHTML = html
    })
  }

  updateNotices (notices) {
    this.serviceNoticeTargets.forEach((notice) => {
      const key = notice.dataset.serviceNoticeKey
      const visible = notices[key] === true
      notice.classList.toggle('hidden', !visible)
    })
  }

  updateUploadAvailability (allowed) {
    this.uploadRootTargets.forEach((root) => {
      root.dataset.receiptUploadOcrAvailableValue = allowed ? 'true' : 'false'
    })

    this.uploadControlTargets.forEach((control) => {
      control.disabled = !allowed
    })

    this.uploadSubmitTargets.forEach((button) => {
      const root = this.nearestUploadRoot(button)
      const hasSelectedFile = root ? this.hasSelectedFile(root) : false
      button.disabled = !allowed || !hasSelectedFile
    })
  }

  updateOcrGatedLinks (allowed) {
    this.ocrGatedLinkTargets.forEach((element) => {
      if (allowed) {
        this.enableOcrGatedElement(element)
      } else {
        this.disableOcrGatedElement(element)
      }
    })
  }

  updateServiceBadges (payload) {
    this.serviceBadgeTargets.forEach((container) => {
      const service = container.dataset.service
      const badgeHtml = payload?.[service]?.badge_html
      if (!badgeHtml) return

      container.innerHTML = badgeHtml
    })
  }

  enableOcrGatedElement (element) {
    const href = element.dataset.enabledHref
    if (!href) return

    const enabledElement = this.replaceElementTag(element, 'a')
    enabledElement.setAttribute('href', href)
    enabledElement.removeAttribute('role')
    enabledElement.removeAttribute('aria-disabled')
    enabledElement.removeAttribute('data-service-disabled')
    enabledElement.classList.remove('opacity-60', 'cursor-not-allowed')
  }

  disableOcrGatedElement (element) {
    const disabledElement = this.replaceElementTag(element, 'div')
    disabledElement.removeAttribute('href')
    disabledElement.setAttribute('role', 'link')
    disabledElement.setAttribute('aria-disabled', 'true')
    disabledElement.dataset.serviceDisabled = 'ocr'
    disabledElement.classList.add('opacity-60', 'cursor-not-allowed')
  }

  replaceElementTag (element, tagName) {
    if (element.tagName.toLowerCase() === tagName) return element

    const replacement = document.createElement(tagName)
    Array.from(element.attributes).forEach((attribute) => {
      replacement.setAttribute(attribute.name, attribute.value)
    })
    replacement.innerHTML = element.innerHTML
    element.replaceWith(replacement)
    return replacement
  }

  nearestUploadRoot (element) {
    return element.closest('[data-service-status-polling-target~="uploadRoot"]')
  }

  hasSelectedFile (root) {
    return Array.from(root.querySelectorAll('input[type="file"]')).some((input) => {
      return input.files && input.files.length > 0
    })
  }
}
