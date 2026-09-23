import { Controller } from '@hotwired/stimulus'

const VIEWPORT_MARGIN = 8
const HOVER_CLOSE_DELAY_MS = 120
const AUTO_DISMISS_DELAY_MS = 8000

export default class extends Controller {
  static targets = ['trigger', 'panel']
  static values = {
    autoDismiss: Boolean,
    autoDismissDelay: { type: Number, default: AUTO_DISMISS_DELAY_MS },
    closeOnOutside: { type: Boolean, default: true }
  }

  connect () {
    this.trigger = this.triggerTarget
    this.panel = this.panelTarget
    this.closeButton = this.panel.querySelector('[data-tip-close]')
    this.placeholder = document.createComment('tip-panel')
    this.panel.before(this.placeholder)
    this.listeners = []
    this.dismissTimer = null
    this.hoverTimer = null
    this.pinned = false
    this.triggerHovered = false
    this.panelHovered = false

    this.listen(this.trigger, 'click', this.toggle)
    this.listen(this.trigger, 'pointerenter', this.handlePointerEnter)
    this.listen(this.trigger, 'pointerleave', this.handlePointerLeave)
    this.listen(this.panel, 'pointerenter', this.handlePanelPointerEnter)
    this.listen(this.panel, 'pointerleave', this.handlePanelPointerLeave)
    this.listen(this.panel, 'focusin', this.clearTimers)
    this.listen(this.panel, 'focusout', this.handleFocusOut)
    this.listen(this.closeButton, 'click', this.handleCloseButtonClick)
    this.listen(document, 'pointerdown', this.handleDocumentPointerDown)
    this.listen(document, 'keydown', this.handleDocumentKeydown)
    this.listen(document, 'turbo:before-cache', this.close)
    this.listen(window, 'resize', this.handleViewportChange)
    this.listen(window, 'scroll', this.handleViewportChange, true)
    this.listen(window.visualViewport, 'resize', this.handleViewportChange)
    this.listen(window.visualViewport, 'scroll', this.handleViewportChange)
  }

  disconnect () {
    this.close()
    this.listeners.forEach(([element, name, handler, capture]) => element.removeEventListener(name, handler, capture))
    this.listeners = []
    this.placeholder.remove()
  }

  listen (element, name, callback, capture = false) {
    if (!element) return

    const handler = callback.bind(this)
    element.addEventListener(name, handler, capture)
    this.listeners.push([element, name, handler, capture])
  }

  toggle (event) {
    event.preventDefault()
    if (!this.panel.hidden && this.pinned) {
      this.close({ restoreFocus: true })
      return
    }

    this.pinned = true
    this.open()
    if (event.detail === 0) {
      this.panel.focus({ preventScroll: true })
      this.clearTimers()
    }
  }

  open () {
    this.clearTimers()
    document.body.appendChild(this.panel)
    this.panel.hidden = false
    this.trigger.setAttribute('aria-expanded', 'true')
    this.positionPanel()
    this.startAutoDismissTimer()
  }

  close ({ restoreFocus = false } = {}) {
    this.clearTimers()
    this.panel.hidden = true
    this.trigger.setAttribute('aria-expanded', 'false')
    this.pinned = false
    this.triggerHovered = false
    this.panelHovered = false
    if (this.placeholder.parentNode) {
      this.placeholder.after(this.panel)
    } else {
      this.panel.remove()
    }
    if (restoreFocus && this.trigger.isConnected) this.trigger.focus({ preventScroll: true })
  }

  handlePointerEnter (event) {
    if (event.pointerType === 'touch' || !window.matchMedia('(hover: hover)').matches) return

    this.triggerHovered = true
    this.open()
  }

  handlePointerLeave (event) {
    this.triggerHovered = false
    this.startAutoDismissTimer()
    if (this.panel.contains(event.relatedTarget)) return

    this.scheduleHoverClose()
  }

  handlePanelPointerEnter (event) {
    if (event.pointerType === 'touch') return

    this.panelHovered = true
    this.clearTimers()
  }

  handlePanelPointerLeave () {
    this.panelHovered = false
    this.startAutoDismissTimer()
    this.scheduleHoverClose()
  }

  handleFocusOut (event) {
    if (this.panel.contains(event.relatedTarget)) return

    queueMicrotask(() => {
      if (this.panel.hidden) return

      this.startAutoDismissTimer()
      this.scheduleHoverClose()
    })
  }

  scheduleHoverClose () {
    if (this.pinned || this.triggerHovered || this.panelHovered || this.panel.contains(document.activeElement)) return

    this.clearTimers()
    this.hoverTimer = window.setTimeout(() => this.close(), HOVER_CLOSE_DELAY_MS)
  }

  handleCloseButtonClick (event) {
    event.preventDefault()
    this.close({ restoreFocus: true })
  }

  handleDocumentPointerDown (event) {
    if (this.panel.hidden || !this.closeOnOutsideValue) return
    if (this.trigger.contains(event.target) || this.panel.contains(event.target)) return

    this.close()
  }

  handleDocumentKeydown (event) {
    if (event.key !== 'Escape' || this.panel.hidden) return

    event.preventDefault()
    this.close({ restoreFocus: true })
  }

  handleViewportChange () {
    if (!this.panel.hidden) this.positionPanel()
  }

  positionPanel () {
    const viewport = this.viewportBounds()
    const panel = this.panel
    panel.style.maxWidth = `${Math.max(0, viewport.width - VIEWPORT_MARGIN * 2)}px`
    panel.style.maxHeight = `${Math.max(0, viewport.height - VIEWPORT_MARGIN * 2)}px`
    panel.style.left = '0px'
    panel.style.top = '0px'
    panel.style.visibility = 'hidden'

    const anchor = this.trigger.getBoundingClientRect()
    const rect = panel.getBoundingClientRect()
    const centeredLeft = anchor.left + (anchor.width - rect.width) / 2
    const centeredTop = anchor.top + (anchor.height - rect.height) / 2
    const placements = [
      { top: anchor.bottom + VIEWPORT_MARGIN, left: centeredLeft },
      { top: anchor.top - rect.height - VIEWPORT_MARGIN, left: centeredLeft },
      { top: centeredTop, left: anchor.right + VIEWPORT_MARGIN },
      { top: centeredTop, left: anchor.left - rect.width - VIEWPORT_MARGIN }
    ]
    const position = placements.find(({ top, left }) => (
      left >= viewport.left + VIEWPORT_MARGIN &&
      top >= viewport.top + VIEWPORT_MARGIN &&
      left + rect.width <= viewport.right - VIEWPORT_MARGIN &&
      top + rect.height <= viewport.bottom - VIEWPORT_MARGIN
    )) || placements[0]
    const clampedLeft = this.clamp(
      position.left,
      viewport.left + VIEWPORT_MARGIN,
      viewport.right - rect.width - VIEWPORT_MARGIN
    )
    const clampedTop = this.clamp(
      position.top,
      viewport.top + VIEWPORT_MARGIN,
      viewport.bottom - rect.height - VIEWPORT_MARGIN
    )

    panel.style.left = `${Math.round(clampedLeft)}px`
    panel.style.top = `${Math.round(clampedTop)}px`
    panel.style.visibility = 'visible'
  }

  viewportBounds () {
    const viewport = window.visualViewport
    const left = viewport?.offsetLeft || 0
    const top = viewport?.offsetTop || 0
    const width = viewport?.width || window.innerWidth
    const height = viewport?.height || window.innerHeight
    return { left, top, width, height, right: left + width, bottom: top + height }
  }

  clamp (value, min, max) {
    return Math.min(Math.max(value, min), Math.max(min, max))
  }

  startAutoDismissTimer () {
    if (!this.autoDismissValue || this.panel.hidden || this.triggerHovered || this.panelHovered || this.panel.contains(document.activeElement)) return

    this.clearTimers()
    const configuredDelay = this.autoDismissDelayValue
    const delay = Number.isFinite(configuredDelay) && configuredDelay > 0 ? configuredDelay : AUTO_DISMISS_DELAY_MS
    this.dismissTimer = window.setTimeout(() => this.close(), delay)
  }

  clearTimers () {
    if (this.dismissTimer !== null) window.clearTimeout(this.dismissTimer)
    if (this.hoverTimer !== null) window.clearTimeout(this.hoverTimer)
    this.dismissTimer = null
    this.hoverTimer = null
  }
}
