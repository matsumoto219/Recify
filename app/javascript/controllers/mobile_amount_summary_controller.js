import { Controller } from '@hotwired/stimulus'
import {
  REVIEW_REASON_TARGET_LINK_SELECTOR,
  reviewTargetIdFromHash,
  reviewTargetUrl,
  samePageReviewTargetUrl
} from 'receipts/review_targets'

const DESKTOP_MEDIA_QUERY = '(min-width: 1024px)'
const DETAILS_MEDIA_QUERY = '(min-width: 768px)'

export default class extends Controller {
  static targets = ['details', 'toggle', 'icon']

  static values = {
    openLabel: String,
    closeLabel: String,
    reviewTarget: String
  }

  connect () {
    this.handleBreakpointChange = this.handleBreakpointChange.bind(this)
    this.handleBeforeCache = this.handleBeforeCache.bind(this)
    this.handleHashChange = this.handleHashChange.bind(this)
    this.handleKeyboardVisibilityChange = this.handleKeyboardVisibilityChange.bind(this)
    this.handleReviewTargetClick = this.handleReviewTargetClick.bind(this)

    this.desktopMedia = window.matchMedia(DESKTOP_MEDIA_QUERY)
    this.detailsMedia = window.matchMedia(DETAILS_MEDIA_QUERY)
    if (typeof this.desktopMedia.addEventListener === 'function') {
      this.desktopMedia.addEventListener('change', this.handleBreakpointChange)
    } else {
      this.desktopMedia.addListener(this.handleBreakpointChange)
    }
    if (typeof this.detailsMedia.addEventListener === 'function') {
      this.detailsMedia.addEventListener('change', this.handleBreakpointChange)
    } else {
      this.detailsMedia.addListener(this.handleBreakpointChange)
    }
    document.addEventListener('turbo:before-cache', this.handleBeforeCache)
    document.addEventListener('click', this.handleReviewTargetClick)
    window.addEventListener('hashchange', this.handleHashChange)
    window.addEventListener('mobile-ui:keyboard-visibility-change', this.handleKeyboardVisibilityChange)

    this.element.dataset.mobileAmountSummaryEnhanced = 'true'
    this.element.dataset.mobileAmountSummaryKeyboardVisible = 'false'
    this.syncForViewport()
    this.openFromLocationHash()
    this.setupContentInset()
  }

  disconnect () {
    if (typeof this.desktopMedia?.removeEventListener === 'function') {
      this.desktopMedia.removeEventListener('change', this.handleBreakpointChange)
    } else {
      this.desktopMedia?.removeListener(this.handleBreakpointChange)
    }
    if (typeof this.detailsMedia?.removeEventListener === 'function') {
      this.detailsMedia.removeEventListener('change', this.handleBreakpointChange)
    } else {
      this.detailsMedia?.removeListener(this.handleBreakpointChange)
    }
    document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
    document.removeEventListener('click', this.handleReviewTargetClick)
    window.removeEventListener('hashchange', this.handleHashChange)
    window.removeEventListener('mobile-ui:keyboard-visibility-change', this.handleKeyboardVisibilityChange)
    this.resetContentInset()
  }

  toggle (event) {
    event.preventDefault()
    if (this.detailsMedia.matches || this.keyboardVisible()) return

    this.setOpen(!this.detailsOpen())
  }

  handleBreakpointChange () {
    this.syncForViewport()
  }

  handleKeyboardVisibilityChange (event) {
    const visible = Boolean(event.detail?.visible)
    const inset = Math.max(0, Number(event.detail?.inset) || 0)
    this.element.dataset.mobileAmountSummaryKeyboardVisible = String(visible)
    this.element.style.setProperty('--mobile-amount-keyboard-inset', `${inset}px`)

    if (this.desktopMedia.matches) {
      this.setOpen(true)
    } else if (visible) {
      this.setOpen(false)
    } else if (this.detailsMedia.matches) {
      this.setOpen(true)
    }
  }

  handleBeforeCache () {
    this.resetContentInset()
    this.element.dataset.mobileAmountSummaryKeyboardVisible = 'false'
    this.element.style.removeProperty('--mobile-amount-keyboard-inset')
    this.setOpen(true)
    delete this.element.dataset.mobileAmountSummaryEnhanced
  }

  handleHashChange () {
    this.openFromLocationHash()
  }

  handleReviewTargetClick (event) {
    const link = event.target?.closest?.(REVIEW_REASON_TARGET_LINK_SELECTOR)
    if (!link) return

    const url = reviewTargetUrl(link.getAttribute('href'), window.location.href)
    if (!url || !samePageReviewTargetUrl(url, window.location)) return
    if (reviewTargetIdFromHash(url.hash) !== this.reviewTargetValue) return

    if (!this.desktopMedia.matches && !this.keyboardVisible()) this.setOpen(true)
  }

  syncForViewport () {
    if (this.desktopMedia.matches) {
      this.setOpen(true)
    } else if (this.keyboardVisible()) {
      this.setOpen(false)
    } else {
      this.setOpen(this.detailsMedia.matches)
    }
  }

  openFromLocationHash () {
    if (this.desktopMedia.matches || this.keyboardVisible()) return
    if (reviewTargetIdFromHash(window.location.hash) !== this.reviewTargetValue) return

    this.setOpen(true)
  }

  setOpen (open) {
    this.element.classList.toggle('receipt-amount-summary-details-open', open)
    this.detailsTarget.classList.toggle('is-open', open)
    this.detailsTarget.toggleAttribute('inert', !open)
    this.detailsTarget.setAttribute('aria-hidden', String(!open))
    this.toggleTarget.setAttribute('aria-expanded', String(open))
    this.toggleTarget.setAttribute('aria-label', open ? this.closeLabelValue : this.openLabelValue)
    this.iconTarget.classList.toggle('rotate-180', open)
  }

  detailsOpen () {
    return this.detailsTarget.classList.contains('is-open')
  }

  keyboardVisible () {
    return this.element.dataset.mobileAmountSummaryKeyboardVisible === 'true'
  }

  setupContentInset () {
    this.contentElement = this.element.closest('.receipt-form-content')
    if (!this.contentElement) return

    this.syncContentInset()
    if (typeof window.ResizeObserver !== 'function') return

    this.contentInsetObserver = new window.ResizeObserver(() => this.syncContentInset())
    this.contentInsetObserver.observe(this.element)
  }

  syncContentInset () {
    if (!this.contentElement) return

    const summaryHeight = Math.ceil(this.element.getBoundingClientRect().height)
    if (summaryHeight <= 0) return

    const heightValue = `${summaryHeight}px`
    if (this.contentElement.style.getPropertyValue('--receipt-mobile-amount-summary-height') === heightValue) return

    this.contentElement.style.setProperty('--receipt-mobile-amount-summary-height', heightValue)
  }

  resetContentInset () {
    this.contentInsetObserver?.disconnect()
    this.contentInsetObserver = null
    this.contentElement?.style.removeProperty('--receipt-mobile-amount-summary-height')
    this.contentElement = null
  }
}
