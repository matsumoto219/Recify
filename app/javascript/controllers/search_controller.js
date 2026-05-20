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
    this.close()
    this.debounceTimer = null
    this.searchAbortController = null
    this.searchSequence = 0
    document.addEventListener('pointerdown', this.handleOutsideTap)
    document.addEventListener('keydown', this.handleKeydown)
    document.addEventListener('turbo:before-cache', this.handleBeforeCache)
  }

  disconnect () {
    document.removeEventListener('pointerdown', this.handleOutsideTap)
    document.removeEventListener('keydown', this.handleKeydown)
    document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
    clearTimeout(this.debounceTimer)
    this.abortCurrentSearch()
  }

  open () {
    if (!this.hasPanelTarget) return

    this.panelTarget.classList.remove('hidden')
    this.syncToggle(true)

    if (this.hasInputTarget) {
      requestAnimationFrame(() => this.inputTarget.focus())
    }
  }

  close () {
    if (!this.hasPanelTarget) return

    this.panelTarget.classList.add('hidden')
    this.syncToggle(false)
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
    this.close()
  }

  handleInput (event) {
    const input = event.currentTarget

    clearTimeout(this.debounceTimer)

    this.debounceTimer = setTimeout(() => {
      this.performSearch(input)
    }, 300)
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
