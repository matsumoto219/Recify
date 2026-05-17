import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['panel', 'input']

  connect () {
    this.handleOutsideTap = this.handleOutsideTap.bind(this)
    this.close()
    this.debounceTimer = null
    document.addEventListener('pointerdown', this.handleOutsideTap)
  }

  disconnect () {
    document.removeEventListener('pointerdown', this.handleOutsideTap)
    clearTimeout(this.debounceTimer)
  }

  open () {
    if (!this.hasPanelTarget) return

    this.panelTarget.classList.remove('hidden')

    if (this.hasInputTarget) {
      requestAnimationFrame(() => this.inputTarget.focus())
    }
  }

  close () {
    if (!this.hasPanelTarget) return

    this.panelTarget.classList.add('hidden')
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

    const query = input.value.trim()

    const url = new URL(window.location.href)
    if (query) {
      url.searchParams.set('q', query)
    } else {
      url.searchParams.delete('q')
    }

    try {
      const response = await fetch(url, {
        headers: {
          Accept: 'text/html'
        }
      })

      if (!response.ok) return

      const html = await response.text()
      const parser = new DOMParser()
      const doc = parser.parseFromString(html, 'text/html')
      const newResults = doc.querySelector('#receipts-results')
      const newPageHeader = doc.querySelector('#receipts-page-header')
      const newSummary = doc.querySelector('#receipts-summary')

      if (newResults) {
        results.innerHTML = newResults.innerHTML
      }

      if (pageHeader && newPageHeader) {
        pageHeader.innerHTML = newPageHeader.innerHTML
      }

      if (summary && newSummary) {
        summary.innerHTML = newSummary.innerHTML
      }
    } catch (error) {
      console.error('Search failed:', error)
    }
  }
}
