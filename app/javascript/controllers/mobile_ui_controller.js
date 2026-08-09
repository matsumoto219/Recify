// app/javascript/controllers/mobile_ui_controller.js
import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['nav']

  connect () {
    this.keyboardThreshold = 100
    this.isFormFocused = false
    this.isKeyboardVisible = false
    this.keyboardProbePending = false
    this.initialViewportHeight = this.currentViewportHeight()
    this.initialViewportWidth = window.innerWidth

    this.handleBeforeCache = this.handleBeforeCache.bind(this)
    this.handleViewportResize = this.handleViewportResize.bind(this)
    this.handleFocusIn = this.handleFocusIn.bind(this)
    this.handleFocusOut = this.handleFocusOut.bind(this)

    document.addEventListener('turbo:before-cache', this.handleBeforeCache)
    window.addEventListener('focusin', this.handleFocusIn)
    window.addEventListener('focusout', this.handleFocusOut)
    window.visualViewport?.addEventListener('resize', this.handleViewportResize)
    window.visualViewport?.addEventListener('scroll', this.handleViewportResize)
  }

  disconnect () {
    window.clearTimeout(this.focusVerificationTimeout)
    window.clearTimeout(this.focusOutTimeout)

    document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
    window.removeEventListener('focusin', this.handleFocusIn)
    window.removeEventListener('focusout', this.handleFocusOut)
    window.visualViewport?.removeEventListener('resize', this.handleViewportResize)
    window.visualViewport?.removeEventListener('scroll', this.handleViewportResize)
  }

  handleBeforeCache () {
    window.clearTimeout(this.focusVerificationTimeout)
    window.clearTimeout(this.focusOutTimeout)
    this.isFormFocused = false
    this.isKeyboardVisible = false
    this.keyboardProbePending = false
    this.initialViewportHeight = this.currentViewportHeight()
    this.initialViewportWidth = window.innerWidth
    this.showNav()
    this.notifyKeyboardVisibility(false)
  }

  handleViewportResize () {
    const currentHeight = this.currentViewportHeight()
    const currentWidth = window.innerWidth

    if (Math.abs(this.initialViewportWidth - currentWidth) > 1) {
      const inset = this.keyboardInset()
      const keyboardWasConfirmedVisible = this.isKeyboardVisible && !this.keyboardProbePending
      const keyboardNeedsVerification = this.isFormFocused &&
        inset <= this.keyboardThreshold &&
        keyboardWasConfirmedVisible

      this.initialViewportHeight = currentHeight + inset
      this.initialViewportWidth = currentWidth
      this.isKeyboardVisible = this.isFormFocused &&
        (inset > this.keyboardThreshold || keyboardWasConfirmedVisible)
      this.keyboardProbePending = keyboardNeedsVerification
      window.clearTimeout(this.focusVerificationTimeout)

      if (this.isKeyboardVisible) {
        this.hideNav()
        this.notifyKeyboardVisibility(true)
        if (keyboardNeedsVerification) this.scheduleFocusVerification()
      } else {
        this.showNav()
        this.notifyKeyboardVisibility(false)
      }
      return
    }

    const heightDiff = this.initialViewportHeight - currentHeight

    this.isKeyboardVisible = this.isFormFocused && heightDiff > this.keyboardThreshold

    if (this.isKeyboardVisible) {
      this.keyboardProbePending = false
      window.clearTimeout(this.focusVerificationTimeout)
      this.hideNav()
      this.notifyKeyboardVisibility(true)
      return
    }

    if (this.isFormFocused && this.keyboardProbePending) {
      this.scheduleFocusVerification()
      return
    }

    if (!this.isFormFocused) {
      this.initialViewportHeight = currentHeight
      this.initialViewportWidth = currentWidth
    }

    this.showNav()
    this.notifyKeyboardVisibility(false)
  }

  handleFocusIn (event) {
    if (!this.isFormControl(event.target)) return

    window.clearTimeout(this.focusVerificationTimeout)
    window.clearTimeout(this.focusOutTimeout)
    this.isFormFocused = true

    const keyboardConfirmedByGeometry = this.keyboardInset() > this.keyboardThreshold ||
      this.initialViewportHeight - this.currentViewportHeight() > this.keyboardThreshold

    if (this.isKeyboardVisible && keyboardConfirmedByGeometry) {
      this.keyboardProbePending = false
      return
    }

    this.keyboardProbePending = true
    this.scheduleFocusVerification()
  }

  handleFocusOut (event) {
    if (!this.isFormControl(event.target)) return

    window.clearTimeout(this.focusVerificationTimeout)
    this.isFormFocused = false
    this.keyboardProbePending = false

    // キーボード収納アニメーション後に visualViewport の値を確認する
    window.clearTimeout(this.focusOutTimeout)
    this.focusOutTimeout = window.setTimeout(() => {
      this.focusOutTimeout = null
      this.handleViewportResize()
    }, 150)
  }

  currentViewportHeight () {
    return window.visualViewport?.height || window.innerHeight
  }

  scheduleFocusVerification () {
    window.clearTimeout(this.focusVerificationTimeout)
    this.focusVerificationTimeout = window.setTimeout(() => {
      this.focusVerificationTimeout = null
      this.keyboardProbePending = false
      this.handleViewportResize()
    }, 150)
  }

  keyboardInset () {
    const viewport = window.visualViewport
    if (!viewport) return 0

    const viewportHeight = Number(viewport.height) || window.innerHeight
    const viewportOffsetTop = Number(viewport.offsetTop) || 0
    return Math.max(0, window.innerHeight - viewportHeight - viewportOffsetTop)
  }

  notifyKeyboardVisibility (visible) {
    this.dispatch('keyboard-visibility-change', {
      target: window,
      detail: {
        visible,
        inset: visible ? this.keyboardInset() : 0
      }
    })
  }

  isFormControl (element) {
    return element instanceof HTMLInputElement ||
      element instanceof HTMLTextAreaElement ||
      element instanceof HTMLSelectElement
  }

  showNav () {
    if (!this.hasNavTarget) return

    this.element.classList.remove('pointer-events-none')
    this.navTarget.classList.remove('translate-y-full', 'opacity-0', 'pointer-events-none')
    this.navTarget.toggleAttribute('inert', false)
    this.navTarget.removeAttribute('aria-hidden')
  }

  hideNav () {
    if (!this.hasNavTarget) return

    this.element.classList.add('pointer-events-none')
    this.navTarget.classList.add('translate-y-full', 'opacity-0', 'pointer-events-none')
    this.navTarget.toggleAttribute('inert', true)
    this.navTarget.setAttribute('aria-hidden', 'true')
  }
}
