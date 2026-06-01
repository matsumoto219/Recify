import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['panel', 'input', 'toggle']

  static values = {
    errorTitle: { type: String, default: 'Error' },
    errorMessage: { type: String, default: 'Unable to update search results. Please try again.' },
    errorCloseLabel: { type: String, default: 'Close' }
  }

  connect () {
    this.handleOutsideTap = this.handleOutsideTap.bind(this)
    this.handleKeydown = this.handleKeydown.bind(this)
    this.handleBeforeCache = this.handleBeforeCache.bind(this)
    this.debounceTimer = null
    this.closeTimer = null
    this.openFrame = null
    this.focusFrame = null
    this.searchAbortController = null
    this.searchSequence = 0
    this.isComposing = false
    this.helpHideTimers = new Map()
    this.close({ animated: false })
    document.addEventListener('pointerdown', this.handleOutsideTap)
    document.addEventListener('keydown', this.handleKeydown)
    document.addEventListener('turbo:before-cache', this.handleBeforeCache)
  }

  disconnect () {
    document.removeEventListener('pointerdown', this.handleOutsideTap)
    document.removeEventListener('keydown', this.handleKeydown)
    document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
    clearTimeout(this.debounceTimer)
    this.clearHelpHideTimers()
    this.clearCloseTimer()
    this.cancelOpenFrame()
    this.cancelFocusFrame()
    this.abortCurrentSearch()
  }

  open () {
    if (!this.hasPanelTarget) return

    this.clearCloseTimer()
    this.cancelOpenFrame()
    this.cancelFocusFrame()
    this.panelTarget.classList.remove('hidden')
    this.syncToggle(true)

    if (this.prefersReducedMotion()) {
      this.panelTarget.classList.add('is-open')
      this.focusInput()
      return
    }

    this.openFrame = requestAnimationFrame(() => {
      this.panelTarget.classList.add('is-open')
      this.openFrame = null
      this.focusInput()
    })
  }

  close ({ animated = true } = {}) {
    if (!this.hasPanelTarget) return

    this.clearCloseTimer()
    this.cancelOpenFrame()
    this.cancelFocusFrame()
    this.syncToggle(false)

    if (!animated || this.prefersReducedMotion() || this.panelTarget.classList.contains('hidden')) {
      this.panelTarget.classList.remove('is-open')
      this.panelTarget.classList.add('hidden')
      return
    }

    this.panelTarget.classList.remove('is-open')
    this.closeTimer = setTimeout(() => {
      this.panelTarget.classList.add('hidden')
      this.closeTimer = null
    }, 180)
  }

  focusInput () {
    if (!this.hasInputTarget) return

    this.cancelFocusFrame()
    this.focusFrame = requestAnimationFrame(() => {
      if (!this.hasPanelTarget || this.panelTarget.classList.contains('hidden')) {
        this.focusFrame = null
        return
      }

      this.inputTarget.focus()
      this.focusFrame = null
    })
  }

  toggle () {
    if (!this.hasPanelTarget) return

    if (this.panelTarget.classList.contains('hidden')) {
      this.open()
    } else {
      this.close()
    }
  }

  handleOutsideTap (event) {
    if (!this.hasPanelTarget) return
    if (this.panelTarget.classList.contains('hidden')) return
    if (this.panelTarget.contains(event.target)) return
    if (event.target.closest("[data-action~='search#toggle']")) return

    this.close()
  }

  handleKeydown (event) {
    if (event.key !== 'Escape') return

    this.close()
  }

  handleBeforeCache () {
    this.close({ animated: false })
    this.hideAllHelp()
  }

  handleInput (event) {
    const input = event.currentTarget

    if (!this.isComposing) {
      this.applyAmountInputAssist(input)
      this.applyDateInputAssist(input)
    }

    clearTimeout(this.debounceTimer)

    this.debounceTimer = setTimeout(() => {
      this.performSearch(input)
    }, 300)
  }

  handleCompositionStart () {
    this.isComposing = true
  }

  handleCompositionEnd (event) {
    this.isComposing = false
    this.handleInput(event)
  }

  showHelp (event) {
    const help = this.helpFor(event.currentTarget)
    if (!help) return

    this.clearHelpHideTimer(help)
    help.classList.remove('hidden')
    help.setAttribute('aria-hidden', 'false')
  }

  hideHelp (event) {
    const help = this.helpFor(event.currentTarget)
    if (!help) return

    this.scheduleHelpHide(help)
  }

  handleInputKeydown (event) {
    if (event.key !== 'Escape') return

    this.hideHelp(event)
  }

  keepHelpOpen (event) {
    event.preventDefault()
  }

  insertQueryPrefix (event) {
    event.preventDefault()

    const prefix = event.params.prefix || event.currentTarget.dataset.searchPrefixParam
    const input = this.queryInputFor(event.currentTarget)
    if (!prefix || !input) return

    const currentValue = input.value.replace(/\s+$/, '')
    const separator = currentValue.length > 0 ? ' ' : ''
    input.value = `${currentValue}${separator}${prefix}`

    const cursorPosition = input.value.length
    input.focus()
    input.setSelectionRange(cursorPosition, cursorPosition)
    this.hideAllHelp()
  }

  async performSearch (input) {
    const results = document.getElementById('receipts-results')
    const pageHeader = document.getElementById('receipts-page-header')
    const summary = document.getElementById('receipts-summary')
    if (!input || !results) return

    const searchSequence = this.searchSequence + 1
    this.searchSequence = searchSequence
    this.abortCurrentSearch()

    const abortController = new AbortController()
    this.searchAbortController = abortController

    const query = input.value.trim()

    const url = new URL(window.location.href)
    if (query) {
      url.searchParams.set('q', query)
    } else {
      url.searchParams.delete('q')
    }
    url.searchParams.delete('page')

    try {
      const response = await fetch(url, {
        headers: {
          Accept: 'text/html'
        },
        signal: abortController.signal
      })

      if (!this.isLatestSearch(searchSequence, abortController)) return

      if (!response.ok) {
        this.showSearchErrorNotice()
        return
      }

      const html = await response.text()

      if (!this.isLatestSearch(searchSequence, abortController)) return

      const parser = new DOMParser()
      const doc = parser.parseFromString(html, 'text/html')
      const newResults = doc.querySelector('#receipts-results')
      const newPageHeader = doc.querySelector('#receipts-page-header')
      const newSummary = doc.querySelector('#receipts-summary')

      if (!newResults) {
        this.showSearchErrorNotice()
        return
      }

      results.innerHTML = newResults.innerHTML

      if (pageHeader && newPageHeader) {
        pageHeader.innerHTML = newPageHeader.innerHTML
      }

      if (summary && newSummary) {
        const summaryController = newSummary.querySelector('[data-controller~="receipt-summary"]')
        if (summaryController) {
          summaryController.dataset.receiptSummaryAnimateOnConnectValue = 'true'
        }

        summary.innerHTML = newSummary.innerHTML
      }

      window.history.replaceState(window.history.state, '', url)
      this.removeSearchErrorNotice()
    } catch (error) {
      if (error.name === 'AbortError') return
      if (!this.isLatestSearch(searchSequence, abortController)) return

      this.showSearchErrorNotice()
      console.error('Search failed:', error)
    } finally {
      if (this.searchAbortController === abortController) {
        this.searchAbortController = null
      }
    }
  }

  abortCurrentSearch () {
    if (!this.searchAbortController) return

    this.searchAbortController.abort()
    this.searchAbortController = null
  }

  isLatestSearch (searchSequence, abortController) {
    return this.searchSequence === searchSequence && this.searchAbortController === abortController
  }

  syncToggle (expanded) {
    if (!this.hasToggleTarget) return

    this.toggleTarget.setAttribute('aria-expanded', String(expanded))
  }

  clearCloseTimer () {
    if (!this.closeTimer) return

    clearTimeout(this.closeTimer)
    this.closeTimer = null
  }

  cancelOpenFrame () {
    if (this.openFrame === null) return

    cancelAnimationFrame(this.openFrame)
    this.openFrame = null
  }

  cancelFocusFrame () {
    if (this.focusFrame === null) return

    cancelAnimationFrame(this.focusFrame)
    this.focusFrame = null
  }

  prefersReducedMotion () {
    return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }

  helpFor (element) {
    const box = element.closest('[data-search-box]')
    if (!box) return null

    return box.querySelector('[data-search-help]')
  }

  hideAllHelp () {
    this.clearHelpHideTimers()
    this.element.querySelectorAll('[data-search-help]').forEach((help) => {
      help.classList.add('hidden')
      help.setAttribute('aria-hidden', 'true')
    })
  }

  scheduleHelpHide (help) {
    this.clearHelpHideTimer(help)

    const timer = setTimeout(() => {
      if (help.contains(document.activeElement)) return

      help.classList.add('hidden')
      help.setAttribute('aria-hidden', 'true')
      this.helpHideTimers.delete(help)
    }, 120)

    this.helpHideTimers.set(help, timer)
  }

  clearHelpHideTimer (help) {
    const timer = this.helpHideTimers.get(help)
    if (!timer) return

    clearTimeout(timer)
    this.helpHideTimers.delete(help)
  }

  clearHelpHideTimers () {
    this.helpHideTimers.forEach((timer) => {
      clearTimeout(timer)
    })
    this.helpHideTimers.clear()
  }

  queryInputFor (element) {
    const box = element.closest('[data-search-box]')
    if (!box) return null

    return box.querySelector('[data-search-query-input]')
  }

  applyDateInputAssist (input) {
    if (!input || input.selectionStart === null || input.selectionStart !== input.selectionEnd) return

    const value = input.value
    const cursor = input.selectionStart
    const tokenRange = this.currentTokenRange(value, cursor)
    if (!tokenRange) return
    if (cursor !== tokenRange.end) return

    const token = value.slice(tokenRange.start, tokenRange.end)
    const match = token.match(/^(date(?:>=|<=))(.+)$/)
    if (!match) return

    const prefix = match[1]
    const rawDateValue = match[2]
    if (!/^[\d/-]+$/.test(rawDateValue)) return

    const digits = rawDateValue.replace(/[^\d]/g, '')
    if (digits.length === 0 || digits.length > 8) return

    const formattedDate = this.formatDateDigits(digits)
    if (!formattedDate) return

    const formattedToken = `${prefix}${formattedDate}`
    if (formattedToken === token) return

    input.value = `${value.slice(0, tokenRange.start)}${formattedToken}${value.slice(tokenRange.end)}`

    const newCursor = tokenRange.start + formattedToken.length
    input.setSelectionRange(newCursor, newCursor)
  }

  applyAmountInputAssist (input) {
    if (!input || input.selectionStart === null || input.selectionStart !== input.selectionEnd) return

    const value = input.value
    const cursor = input.selectionStart
    const normalized = this.normalizeAmountExpressions(value)
    if (normalized === value) return

    input.value = normalized
    const newCursor = Math.max(0, cursor - (value.length - normalized.length))
    input.setSelectionRange(newCursor, newCursor)
  }

  normalizeAmountExpressions (value) {
    return value.replace(
      /(^|\s)((?:amount)?(?:>=|<=))\s*([¥￥]?\s*\d[\d,]*)/gi,
      (_match, leadingSpace, prefix, rawAmount) => {
        const amount = rawAmount.replace(/[¥￥,\s]/g, '')
        return `${leadingSpace}${prefix}${amount}`
      }
    )
  }

  currentTokenRange (value, cursor) {
    let start = cursor
    while (start > 0 && !/\s/.test(value[start - 1])) {
      start -= 1
    }

    let end = cursor
    while (end < value.length && !/\s/.test(value[end])) {
      end += 1
    }

    if (start === end) return null

    return { start, end }
  }

  formatDateDigits (digits) {
    if (digits.length <= 3) return digits
    if (digits.length === 4) return `${digits}-`
    if (digits.length <= 5) return `${digits.slice(0, 4)}-${digits.slice(4)}`
    if (digits.length === 6) return `${digits.slice(0, 4)}-${digits.slice(4, 6)}-`

    return `${digits.slice(0, 4)}-${digits.slice(4, 6)}-${digits.slice(6, 8)}`
  }

  showSearchErrorNotice () {
    const flash = document.getElementById('flash')
    if (!flash) return

    this.removeSearchErrorNotice()

    const container = document.createElement('div')
    container.id = 'search-error-toast-container'
    container.className = 'fixed top-4 md:top-20 left-1/2 -translate-x-1/2 md:left-auto md:right-4 md:translate-x-0 z-[9999] flex flex-col gap-3 pointer-events-none w-full max-w-[calc(100%-2rem)] md:max-w-sm'

    const notice = document.createElement('div')
    notice.id = 'search-error-toast'
    notice.className = 'pointer-events-auto notice-glass notice-surface notice-surface-error p-4 flex gap-3 items-center opacity-0 translate-x-full transition-all duration-300 ease-out'
    notice.setAttribute('role', 'alert')
    notice.setAttribute('aria-live', 'polite')
    notice.setAttribute('data-controller', 'notice-surface')
    notice.setAttribute('data-notice-surface-animation-value', 'slide_right')
    notice.setAttribute('data-notice-surface-auto-dismiss-value', 'true')
    notice.setAttribute('data-notice-surface-auto-dismiss-delay-value', '7000')
    notice.setAttribute('data-notice-surface-max-visible-value', '3')

    const iconWrapper = document.createElement('div')
    iconWrapper.className = 'flex-shrink-0 w-8 h-8 rounded-lg token-state-error-soft flex items-center justify-center'

    const icon = document.createElement('span')
    icon.className = 'material-symbols-outlined text-[20px]'
    icon.style.fontVariationSettings = "'FILL' 1"
    icon.setAttribute('aria-hidden', 'true')
    icon.textContent = 'error'
    iconWrapper.appendChild(icon)

    const content = document.createElement('div')
    content.className = 'flex-1 min-w-0'

    const title = document.createElement('p')
    title.className = 'text-base font-bold token-text-base leading-tight mb-1'
    title.textContent = this.errorTitleValue

    const message = document.createElement('p')
    message.className = 'min-w-0 max-w-full text-xs token-text-muted leading-relaxed break-words whitespace-pre-wrap'
    message.textContent = this.errorMessageValue

    content.append(title, message)

    const closeButton = document.createElement('button')
    closeButton.type = 'button'
    closeButton.className = 'material-symbols-outlined cursor-pointer text-[18px] opacity-70 hover:opacity-100'
    closeButton.setAttribute('aria-label', this.errorCloseLabelValue)
    closeButton.setAttribute('data-action', 'click->notice-surface#close')
    closeButton.textContent = 'close'

    notice.append(iconWrapper, content, closeButton)
    container.appendChild(notice)
    flash.appendChild(container)
  }

  removeSearchErrorNotice () {
    const toastContainer = document.getElementById('search-error-toast-container')
    const notice = document.getElementById('search-error-toast')
    const container = notice?.parentElement

    notice?.remove()
    toastContainer?.remove()

    if (container?.childElementCount === 0) {
      container.remove()
    }
  }
}
