import { Controller } from '@hotwired/stimulus'

const CLOSE_DURATION_MS = 180
const ORPHANED_PANEL_TTL_MS = 120
const VIEWPORT_MARGIN = 8
const MOBILE_BREAKPOINT = 640
const orphanedPanels = new Map()

// Floating progress panel for processing receipt cards.
export default class extends Controller {
  static targets = ['trigger', 'panel']
  static values = {
    storageKey: String
  }

  connect () {
    this.trigger = this.triggerTarget
    this.panel = this.panelTarget
    this.closeButton = this.panel.querySelector('[data-receipt-processing-popover-close]')
    this.panelPlaceholder = document.createComment('receipt-processing-popover-panel')
    this.panel.before(this.panelPlaceholder)
    this.closeTimer = null
    this.openFrame = null
    this.handleDocumentPointerDown = this.handleDocumentPointerDown.bind(this)
    this.handleDocumentKeydown = this.handleDocumentKeydown.bind(this)
    this.handleViewportChange = this.handleViewportChange.bind(this)
    this.handleAnotherPopoverOpen = this.handleAnotherPopoverOpen.bind(this)
    this.handleCloseButtonClick = this.handleCloseButtonClick.bind(this)
    this.listeningForViewportChanges = false

    document.addEventListener('receipt-processing-popover:open', this.handleAnotherPopoverOpen)
    this.restore()
    this.closeButton?.addEventListener('click', this.handleCloseButtonClick)
  }

  disconnect () {
    this.clearCloseTimer()
    this.cancelOpenFrame()
    this.removeInteractionListeners()
    this.removeViewportListeners()
    this.closeButton?.removeEventListener('click', this.handleCloseButtonClick)
    document.removeEventListener('receipt-processing-popover:open', this.handleAnotherPopoverOpen)

    if (this.shouldParkOpenPanel()) {
      this.parkOpenPanel()
    } else {
      this.panel.remove()
    }

    this.panelPlaceholder.remove()
  }

  toggle (event) {
    event.preventDefault()

    if (this.isOpen()) {
      this.closePopover({ restoreFocus: true })
    } else {
      this.openPopover({ restoreFocus: false })
    }
  }

  close (event) {
    event?.preventDefault()
    this.closePopover({ restoreFocus: true })
  }

  openPopover ({ restoreFocus = false, notify = true, animate = true, preserveVisible = false } = {}) {
    if (!this.trigger || !this.panel) return

    if (notify) {
      document.dispatchEvent(new CustomEvent('receipt-processing-popover:open', { detail: { controller: this } }))
    }

    this.clearCloseTimer()
    this.cancelOpenFrame()
    this.movePanelToBody()
    this.panel.hidden = false
    if (!preserveVisible) this.panel.classList.remove('is-open')
    this.trigger.setAttribute('aria-expanded', 'true')
    this.store(true)
    this.positionPanel()
    this.addInteractionListeners()
    this.addViewportListeners()

    const finishOpen = () => {
      this.panel.classList.add('is-open')
      this.focusPanel({ restoreFocus })
    }

    if (preserveVisible || !animate || this.prefersReducedMotion()) {
      finishOpen()
      return
    }

    this.openFrame = requestAnimationFrame(() => {
      finishOpen()
      this.openFrame = null
    })
  }

  closePopover ({ restoreFocus = false, persist = true } = {}) {
    if (!this.trigger || !this.panel) return

    this.clearCloseTimer()
    this.cancelOpenFrame()
    this.trigger.setAttribute('aria-expanded', 'false')
    this.panel.classList.remove('is-open')
    this.removeInteractionListeners()
    this.removeViewportListeners()
    if (persist) this.store(false)

    const finish = () => {
      this.panel.hidden = true
      this.resetPanelPosition()
      this.movePanelHome()
      if (restoreFocus) this.trigger.focus({ preventScroll: true })
    }

    if (this.prefersReducedMotion()) {
      finish()
      return
    }

    this.closeTimer = window.setTimeout(() => {
      finish()
      this.closeTimer = null
    }, CLOSE_DURATION_MS)
  }

  restore () {
    if (!this.hasStorageKeyValue) return

    const storedOpen = this.withSessionStorage((storage) => storage.getItem(this.storageKeyValue)) === 'open'
    if (!storedOpen) return

    const orphanedPanel = this.takeOrphanedPanel()
    const preserveVisible = Boolean(orphanedPanel)
    if (orphanedPanel) this.adoptOrphanedPanel(orphanedPanel)

    this.openPopover({ restoreFocus: false, notify: true, animate: !preserveVisible, preserveVisible })
  }

  store (open) {
    if (!this.hasStorageKeyValue) return

    this.withSessionStorage((storage) => {
      storage.setItem(this.storageKeyValue, open ? 'open' : 'closed')
    })
  }

  handleAnotherPopoverOpen (event) {
    if (event.detail?.controller === this) return

    this.closePopover({ restoreFocus: false })
  }

  handleDocumentPointerDown (event) {
    if (!this.isOpen()) return
    if (this.element.contains(event.target) || this.panel.contains(event.target)) return

    this.closePopover({ restoreFocus: false })
  }

  handleCloseButtonClick (event) {
    event.preventDefault()
    this.closePopover({ restoreFocus: true })
  }

  handleDocumentKeydown (event) {
    if (event.key !== 'Escape' || !this.isOpen()) return

    event.preventDefault()
    this.closePopover({ restoreFocus: true })
  }

  handleViewportChange () {
    if (!this.isOpen()) return

    this.positionPanel()
  }

  positionPanel () {
    if (!this.trigger || !this.panel) return

    const panel = this.panel
    const triggerRect = this.trigger.getBoundingClientRect()
    let viewport = this.viewportBounds()
    const mobile = viewport.width < MOBILE_BREAKPOINT
    const maxPanelWidth = Math.max(0, viewport.width - (VIEWPORT_MARGIN * 2))

    panel.style.width = mobile ? `${maxPanelWidth}px` : ''
    panel.style.left = '0px'
    panel.style.top = '0px'
    panel.style.visibility = 'hidden'

    let panelRect = panel.getBoundingClientRect()
    viewport = this.viewportBounds()

    if (mobile && panelRect.width > viewport.width - (VIEWPORT_MARGIN * 2)) {
      panel.style.width = `${Math.max(0, viewport.width - (VIEWPORT_MARGIN * 2))}px`
      panelRect = panel.getBoundingClientRect()
    }

    const centeredLeft = triggerRect.left + ((triggerRect.width - panelRect.width) / 2)
    const centeredTop = triggerRect.top + ((triggerRect.height - panelRect.height) / 2)
    const placements = mobile
      ? [
          { top: triggerRect.bottom + VIEWPORT_MARGIN, left: viewport.left + VIEWPORT_MARGIN },
          { top: triggerRect.top - panelRect.height - VIEWPORT_MARGIN, left: viewport.left + VIEWPORT_MARGIN }
        ]
      : [
          { top: triggerRect.bottom + VIEWPORT_MARGIN, left: centeredLeft },
          { top: triggerRect.top - panelRect.height - VIEWPORT_MARGIN, left: centeredLeft },
          { top: centeredTop, left: triggerRect.right + VIEWPORT_MARGIN },
          { top: centeredTop, left: triggerRect.left - panelRect.width - VIEWPORT_MARGIN }
        ]

    const position = placements.find((placement) => this.fitsViewport(placement, panelRect, viewport)) || placements[0]
    const clampedLeft = this.clamp(
      position.left,
      viewport.left + VIEWPORT_MARGIN,
      viewport.right - panelRect.width - VIEWPORT_MARGIN
    )
    const clampedTop = this.clamp(
      position.top,
      viewport.top + VIEWPORT_MARGIN,
      viewport.bottom - panelRect.height - VIEWPORT_MARGIN
    )

    panel.style.left = `${Math.round(clampedLeft)}px`
    panel.style.top = `${Math.round(clampedTop)}px`
    panel.style.visibility = 'visible'
  }

  fitsViewport (placement, rect, viewport) {
    return placement.left >= viewport.left + VIEWPORT_MARGIN &&
      placement.top >= viewport.top + VIEWPORT_MARGIN &&
      placement.left + rect.width <= viewport.right - VIEWPORT_MARGIN &&
      placement.top + rect.height <= viewport.bottom - VIEWPORT_MARGIN
  }

  viewportBounds () {
    const visualViewport = window.visualViewport

    if (!visualViewport) {
      return {
        left: 0,
        top: 0,
        right: window.innerWidth,
        bottom: window.innerHeight,
        width: window.innerWidth,
        height: window.innerHeight
      }
    }

    const left = visualViewport.offsetLeft
    const top = visualViewport.offsetTop
    const width = visualViewport.width
    const height = visualViewport.height

    return {
      left,
      top,
      right: left + width,
      bottom: top + height,
      width,
      height
    }
  }

  clamp (value, min, max) {
    if (max < min) return min

    return Math.min(Math.max(value, min), max)
  }

  isOpen () {
    return this.panel && !this.panel.hidden
  }

  focusPanel ({ restoreFocus = false } = {}) {
    if (restoreFocus || !this.panel) return

    this.panel.focus({ preventScroll: true })
  }

  movePanelToBody () {
    if (this.panel.parentElement === document.body) return

    document.body.appendChild(this.panel)
  }

  movePanelHome () {
    if (!this.panelPlaceholder.isConnected) return
    if (this.panel.parentElement !== document.body) return

    this.panelPlaceholder.after(this.panel)
  }

  shouldParkOpenPanel () {
    if (!this.isOpen() || !this.hasStorageKeyValue) return false

    return this.withSessionStorage((storage) => storage.getItem(this.storageKeyValue)) === 'open'
  }

  parkOpenPanel () {
    const existing = orphanedPanels.get(this.storageKeyValue)
    if (existing) {
      window.clearTimeout(existing.timer)
      window.clearTimeout(existing.removeTimer)
      existing.panel.remove()
    }

    const panel = this.panel
    const timer = window.setTimeout(() => {
      const orphanedPanel = orphanedPanels.get(this.storageKeyValue)
      if (orphanedPanel?.panel !== panel) return

      panel.classList.remove('is-open')

      const removePanel = () => {
        if (orphanedPanels.get(this.storageKeyValue)?.panel !== panel) return

        panel.remove()
        orphanedPanels.delete(this.storageKeyValue)
      }

      if (this.prefersReducedMotion()) {
        removePanel()
      } else {
        orphanedPanel.removeTimer = window.setTimeout(removePanel, CLOSE_DURATION_MS)
      }
    }, ORPHANED_PANEL_TTL_MS)

    orphanedPanels.set(this.storageKeyValue, { panel, timer, removeTimer: null })
  }

  takeOrphanedPanel () {
    if (!this.hasStorageKeyValue) return null

    const orphaned = orphanedPanels.get(this.storageKeyValue)
    if (!orphaned) return null

    window.clearTimeout(orphaned.timer)
    window.clearTimeout(orphaned.removeTimer)
    orphanedPanels.delete(this.storageKeyValue)

    return orphaned.panel
  }

  adoptOrphanedPanel (orphanedPanel) {
    const replacementPanel = this.panel

    this.syncPanelAttributes(orphanedPanel, replacementPanel)
    orphanedPanel.innerHTML = replacementPanel.innerHTML
    replacementPanel.remove()

    this.panel = orphanedPanel
    this.closeButton = this.panel.querySelector('[data-receipt-processing-popover-close]')
  }

  syncPanelAttributes (targetPanel, sourcePanel) {
    const attributesToSync = ['id', 'role', 'aria-modal', 'aria-labelledby', 'tabindex']

    attributesToSync.forEach((attributeName) => {
      const value = sourcePanel.getAttribute(attributeName)

      if (value === null) {
        targetPanel.removeAttribute(attributeName)
      } else {
        targetPanel.setAttribute(attributeName, value)
      }
    })

    targetPanel.hidden = false
  }

  addInteractionListeners () {
    document.addEventListener('pointerdown', this.handleDocumentPointerDown)
    document.addEventListener('keydown', this.handleDocumentKeydown)
  }

  removeInteractionListeners () {
    document.removeEventListener('pointerdown', this.handleDocumentPointerDown)
    document.removeEventListener('keydown', this.handleDocumentKeydown)
  }

  addViewportListeners () {
    if (this.listeningForViewportChanges) return

    window.addEventListener('resize', this.handleViewportChange)
    window.addEventListener('scroll', this.handleViewportChange, true)
    window.visualViewport?.addEventListener('resize', this.handleViewportChange)
    window.visualViewport?.addEventListener('scroll', this.handleViewportChange)
    this.listeningForViewportChanges = true
  }

  removeViewportListeners () {
    if (!this.listeningForViewportChanges) return

    window.removeEventListener('resize', this.handleViewportChange)
    window.removeEventListener('scroll', this.handleViewportChange, true)
    window.visualViewport?.removeEventListener('resize', this.handleViewportChange)
    window.visualViewport?.removeEventListener('scroll', this.handleViewportChange)
    this.listeningForViewportChanges = false
  }

  resetPanelPosition () {
    this.panel.style.left = ''
    this.panel.style.top = ''
    this.panel.style.width = ''
    this.panel.style.visibility = ''
  }

  clearCloseTimer () {
    if (!this.closeTimer) return

    window.clearTimeout(this.closeTimer)
    this.closeTimer = null
  }

  cancelOpenFrame () {
    if (this.openFrame === null) return

    cancelAnimationFrame(this.openFrame)
    this.openFrame = null
  }

  prefersReducedMotion () {
    return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }

  withSessionStorage (callback) {
    try {
      return callback(window.sessionStorage)
    } catch (_error) {
      return null
    }
  }
}
