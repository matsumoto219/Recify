import { Controller } from '@hotwired/stimulus'

const MOBILE_MEDIA_QUERY = '(max-width: 767px)'
const REVEAL_THRESHOLD = 48
const FULL_DELETE_THRESHOLD = 72
const REVEAL_TRANSLATE = 88
const DELETE_ANIMATION_DURATION = 160
const VERTICAL_CANCEL_RATIO = 1
const INTERACTIVE_SELECTOR = [
  'input',
  'textarea',
  'select',
  'button',
  'a',
  'label',
  '[contenteditable]',
  '[data-swipe-ignore]'
].join(',')

export default class extends Controller {
  static targets = ['foreground', 'action']

  connect () {
    this.startX = 0
    this.startY = 0
    this.currentX = 0
    this.dragging = false
    this.cancelled = false
    this.open = false
    this.wasOpenAtStart = false
    this.pointerId = null
    this.handleBeforeCache = this.handleBeforeCache.bind(this)
    this.handleOutsidePointerDown = this.handleOutsidePointerDown.bind(this)
    this.mobileMediaQuery = window.matchMedia?.(MOBILE_MEDIA_QUERY)

    document.addEventListener('turbo:before-cache', this.handleBeforeCache)
    document.addEventListener('pointerdown', this.handleOutsidePointerDown)
  }

  disconnect () {
    document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
    document.removeEventListener('pointerdown', this.handleOutsidePointerDown)
    this.close({ animate: false })
  }

  start (event) {
    if (!this.enabled()) return
    if (event.pointerType === 'mouse' && event.button !== 0) return
    if (this.interactiveElement(event.target)) return

    this.dragging = true
    this.cancelled = false
    this.pointerId = event.pointerId
    this.startX = event.clientX
    this.startY = event.clientY
    this.wasOpenAtStart = this.open
    this.currentX = this.open ? -REVEAL_TRANSLATE : 0
    this.foregroundTarget.setPointerCapture?.(event.pointerId)
    this.setTransition(false)
  }

  move (event) {
    if (!this.dragging || this.cancelled || event.pointerId !== this.pointerId) return

    const deltaX = event.clientX - this.startX
    const deltaY = event.clientY - this.startY

    if (Math.abs(deltaY) > Math.abs(deltaX) * VERTICAL_CANCEL_RATIO) {
      this.cancelSwipe(event)
      return
    }

    if (deltaX > 8 && !this.open) {
      this.cancelSwipe(event)
      return
    }

    event.preventDefault()
    const baseX = this.wasOpenAtStart ? -REVEAL_TRANSLATE : 0
    const minX = this.wasOpenAtStart ? -this.fullTranslateDistance() : -REVEAL_TRANSLATE
    const nextX = this.clamp(baseX + deltaX, minX, 0)
    this.translate(nextX)
  }

  end (event) {
    if (!this.dragging || event.pointerId !== this.pointerId) return

    this.releasePointer(event)

    if (this.cancelled) {
      this.close()
      return
    }

    if (this.shouldDelete(event)) {
      this.fullDelete()
    } else if (Math.abs(this.currentX) >= REVEAL_THRESHOLD) {
      this.reveal()
    } else {
      this.close()
    }
  }

  cancel (event) {
    if (event?.pointerId !== undefined && event.pointerId !== this.pointerId) return

    this.releasePointer(event)
    this.close()
  }

  reveal () {
    if (!this.enabled()) return

    this.open = true
    this.setTransition(true)
    this.translate(-REVEAL_TRANSLATE)
    this.element.dataset.swipeOpen = 'true'
  }

  close ({ animate = true } = {}) {
    if (!this.hasForegroundTarget) return

    this.dragging = false
    this.cancelled = false
    this.pointerId = null
    this.open = false
    this.setTransition(animate)
    this.foregroundTarget.classList.remove('swipe-action-foreground-deleting')
    this.foregroundTarget.style.opacity = ''
    this.translate(0)
    delete this.element.dataset.swipeOpen
  }

  async fullDelete () {
    if (!this.hasActionTarget) {
      this.close()
      return
    }

    if (!(await this.confirmAction())) {
      this.close()
      return
    }

    this.open = false
    this.setTransition(false)
    this.foregroundTarget.classList.toggle('swipe-action-foreground-deleting', !this.prefersReducedMotion())
    this.translate(-this.fullTranslateDistance())
    this.foregroundTarget.style.opacity = '0'
    window.setTimeout(() => this.activateAction(), this.deleteAnimationDuration())
  }

  handleBeforeCache () {
    this.close({ animate: false })
  }

  handleOutsidePointerDown (event) {
    if (!this.open) return
    if (this.element.contains(event.target)) return

    this.close()
  }

  cancelSwipe (event) {
    this.cancelled = true
    this.releasePointer(event)
    this.close()
  }

  releasePointer (event) {
    if (event?.pointerId !== undefined) {
      this.foregroundTarget.releasePointerCapture?.(event.pointerId)
    }
    this.dragging = false
    this.pointerId = null
  }

  translate (value) {
    this.currentX = value
    this.foregroundTarget.style.transform = `translateX(${value}px)`
  }

  activateAction () {
    if (!this.hasActionTarget || !this.element.isConnected) return

    this.actionTarget.dataset.receiptFormSkipDeleteConfirmation = 'true'
    this.actionTarget.click()
  }

  shouldDelete (event) {
    if (!this.wasOpenAtStart) return false

    return this.startX - event.clientX >= FULL_DELETE_THRESHOLD
  }

  confirmAction () {
    const form = this.element.closest('[data-controller~="receipt-form"]')
    const enabled = form?.dataset.receiptFormDeleteConfirmationEnabledValue !== 'false'
    const message = form?.dataset.receiptFormDeleteConfirmationMessageValue || ''
    const title = form?.dataset.receiptFormDeleteConfirmTitleValue || ''
    const confirmLabel = form?.dataset.receiptFormDeleteConfirmLabelValue || ''
    const backdrop = form?.dataset.receiptFormDeleteConfirmBackdropValue || ''

    if (!enabled) return Promise.resolve(true)

    const confirm = window.RecifyConfirm?.confirm
    if (typeof confirm !== 'function') return Promise.resolve(false)

    return confirm(message, {
      variant: 'danger',
      icon: 'delete',
      title,
      confirmLabel,
      backdrop,
      restoreFocusElement: this.actionTarget
    })
  }

  fullTranslateDistance () {
    return Math.max(this.element.clientWidth || 0, REVEAL_TRANSLATE)
  }

  deleteAnimationDuration () {
    return this.prefersReducedMotion() ? 0 : DELETE_ANIMATION_DURATION
  }

  setTransition (enabled) {
    const shouldAnimate = enabled && !this.prefersReducedMotion()
    this.foregroundTarget.classList.toggle('swipe-action-foreground-transition', shouldAnimate)
  }

  enabled () {
    return !this.mobileMediaQuery || this.mobileMediaQuery.matches
  }

  interactiveElement (target) {
    return Boolean(target?.closest?.(INTERACTIVE_SELECTOR))
  }

  prefersReducedMotion () {
    return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }

  clamp (value, min, max) {
    return Math.min(Math.max(value, min), max)
  }
}
