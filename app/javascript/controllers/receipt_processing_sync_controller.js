import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['card']
  static values = {
    url: String,
    interval: { type: Number, default: 3000 },
    slowInterval: { type: Number, default: 10000 },
    fastPollLimit: { type: Number, default: 10 },
    refreshOnTerminal: { type: Boolean, default: false }
  }

  connect () {
    this.connected = true
    this.pollTimer = null
    this.immediateTimer = null
    this.requestAbortController = null
    this.syncInFlight = false
    this.syncAgain = false
    this.completedPollCount = 0
    this.pollingPaused = this.networkOffline()
    this.retryAfterMilliseconds = null
    this.indexRefreshTimer = null
    this.syncFailureReported = false

    this.handleTurboLoad = this.handleTurboLoad.bind(this)
    this.handleBeforeCache = this.handleBeforeCache.bind(this)
    this.handleVisibilityChange = this.handleVisibilityChange.bind(this)
    this.handleOffline = this.handleOffline.bind(this)
    this.handleOnline = this.handleOnline.bind(this)
    this.handleBeforeStreamRender = this.handleBeforeStreamRender.bind(this)
    this.handleCableMutations = this.handleCableMutations.bind(this)

    document.addEventListener('turbo:load', this.handleTurboLoad)
    document.addEventListener('turbo:before-cache', this.handleBeforeCache)
    document.addEventListener('visibilitychange', this.handleVisibilityChange)
    document.addEventListener('turbo:before-stream-render', this.handleBeforeStreamRender)
    window.addEventListener('offline', this.handleOffline)
    window.addEventListener('online', this.handleOnline)
    this.cableObserver = new window.MutationObserver(this.handleCableMutations)
    this.cableObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['connected'],
      subtree: true
    })

    this.queueImmediateSync()
  }

  disconnect () {
    this.connected = false
    document.removeEventListener('turbo:load', this.handleTurboLoad)
    document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
    document.removeEventListener('visibilitychange', this.handleVisibilityChange)
    document.removeEventListener('turbo:before-stream-render', this.handleBeforeStreamRender)
    window.removeEventListener('offline', this.handleOffline)
    window.removeEventListener('online', this.handleOnline)
    this.cableObserver?.disconnect()
    this.cableObserver = null
    this.stopPolling({ abort: true })
    this.clearIndexRefreshTimer()
  }

  cardTargetConnected () {
    if (this.syncInFlight) return

    this.queueImmediateSync()
  }

  cardTargetDisconnected () {
    if (!this.hasCardTarget) this.clearPollTimer()
  }

  handleTurboLoad () {
    this.pollingPaused = this.networkOffline()
    this.queueImmediateSync()
  }

  handleBeforeCache () {
    this.pollingPaused = true
    this.stopPolling({ abort: true })
    this.clearIndexRefreshTimer()
  }

  handleVisibilityChange () {
    if (document.visibilityState === 'hidden') {
      this.pollingPaused = true
      this.stopPolling({ abort: true })
      return
    }

    this.pollingPaused = this.networkOffline()
    this.queueImmediateSync()
  }

  handleOffline () {
    this.pollingPaused = true
    this.stopPolling({ abort: true })
  }

  handleOnline () {
    this.pollingPaused = false
    this.retryAfterMilliseconds = null
    this.queueImmediateSync()
  }

  handleCableMutations (mutations) {
    const reconnected = mutations.some(({ target }) => {
      return target.matches?.('turbo-cable-stream-source[connected]')
    })
    if (reconnected) this.queueImmediateSync()
  }

  handleBeforeStreamRender (event) {
    const streamElement = event.target
    const targetId = streamElement.getAttribute?.('target')
    if (!targetId?.startsWith('receipt_')) return

    const incomingCard = streamElement.querySelector('template')?.content?.firstElementChild
    if (!incomingCard) return

    const currentCard = document.getElementById(targetId)
    if (currentCard && this.olderReceiptCard({ currentCard, incomingCard })) {
      event.preventDefault()
      return
    }

    if (!this.refreshOnTerminalValue || incomingCard.dataset.receiptCardTerminal !== 'true') return

    event.preventDefault()
    this.queueIndexRefresh()
  }

  queueImmediateSync () {
    if (!this.connected || this.pollingPaused || this.networkOffline() || document.visibilityState === 'hidden' || !this.hasCardTarget) return

    this.clearImmediateTimer()
    if (this.syncInFlight) {
      this.syncAgain = true
      return
    }

    this.immediateTimer = window.setTimeout(() => {
      this.immediateTimer = null
      this.syncNow()
    }, 0)
  }

  async syncNow () {
    if (!this.connected || this.pollingPaused || this.networkOffline() || document.visibilityState === 'hidden' || this.syncInFlight) return

    const cardStates = this.processingCardStates()
    if (cardStates.length === 0) {
      this.clearPollTimer()
      return
    }

    this.clearPollTimer()
    this.syncInFlight = true
    const abortController = new AbortController()
    this.requestAbortController = abortController

    try {
      const url = new URL(this.urlValue, window.location.origin)
      cardStates.forEach(({ publicId, stateRevision }) => {
        url.searchParams.append('public_ids[]', publicId)
        url.searchParams.append('state_revisions[]', stateRevision)
      })

      const response = await window.fetch(url, {
        method: 'GET',
        headers: {
          Accept: 'text/vnd.turbo-stream.html',
          'X-Requested-With': 'XMLHttpRequest'
        },
        credentials: 'same-origin',
        cache: 'no-store',
        signal: abortController.signal
      })

      if (response.redirected) {
        Turbo.visit(response.url)
        return
      }
      if (response.status === 429) {
        this.retryAfterMilliseconds = this.retryDelay(response)
        return
      }
      if (!response.ok) {
        this.retryAfterMilliseconds = this.slowIntervalValue
        throw new Error(`Receipt processing sync failed: ${response.status}`)
      }

      const body = await response.text()
      if (body.trim() !== '') Turbo.renderStreamMessage(body)
      this.completedPollCount += 1
      this.syncFailureReported = false
    } catch (error) {
      if (error.name === 'AbortError') return
      if (this.networkOffline()) {
        this.handleOffline()
        return
      }

      this.reportSyncFailure()
    } finally {
      if (this.requestAbortController === abortController) this.requestAbortController = null
      this.syncInFlight = false

      if (this.syncAgain) {
        this.syncAgain = false
        this.queueImmediateSync()
      } else {
        this.scheduleNextPoll()
      }
    }
  }

  processingCardStates () {
    const statesByPublicId = new Map()

    this.cardTargets.forEach((card) => {
      const publicId = card.dataset.receiptCardPublicId
      if (!publicId || statesByPublicId.has(publicId)) return

      statesByPublicId.set(publicId, {
        publicId,
        stateRevision: card.dataset.receiptCardStateRevision || ''
      })
    })

    return [...statesByPublicId.values()]
  }

  scheduleNextPoll () {
    if (!this.connected || this.pollingPaused || this.networkOffline() || document.visibilityState === 'hidden' || !this.hasCardTarget) return

    this.clearPollTimer()
    this.pollTimer = window.setTimeout(() => {
      this.pollTimer = null
      this.syncNow()
    }, this.nextPollDelay())
  }

  stopPolling ({ abort = false } = {}) {
    this.clearImmediateTimer()
    this.clearPollTimer()
    this.syncAgain = false

    if (abort) {
      this.requestAbortController?.abort()
      this.requestAbortController = null
    }
  }

  clearImmediateTimer () {
    if (!this.immediateTimer) return

    window.clearTimeout(this.immediateTimer)
    this.immediateTimer = null
  }

  clearPollTimer () {
    if (!this.pollTimer) return

    window.clearTimeout(this.pollTimer)
    this.pollTimer = null
  }

  queueIndexRefresh () {
    if (this.indexRefreshTimer) return

    this.indexRefreshTimer = window.setTimeout(() => {
      this.indexRefreshTimer = null
      if (!this.connected) return

      Turbo.visit(window.location.href, { action: 'replace' })
    }, 0)
  }

  clearIndexRefreshTimer () {
    if (!this.indexRefreshTimer) return

    window.clearTimeout(this.indexRefreshTimer)
    this.indexRefreshTimer = null
  }

  olderReceiptCard ({ currentCard, incomingCard }) {
    const currentRevision = this.numericData(currentCard.dataset.receiptCardStateRevision)
    const incomingRevision = this.numericData(incomingCard.dataset.receiptCardStateRevision)
    if (incomingRevision < currentRevision) return true
    if (incomingRevision > currentRevision) return false

    const currentPhaseOrder = this.numericData(currentCard.dataset.receiptCardPhaseOrder)
    const incomingPhaseOrder = this.numericData(incomingCard.dataset.receiptCardPhaseOrder)
    if (incomingPhaseOrder < currentPhaseOrder) return true

    const currentTerminal = currentCard.dataset.receiptCardTerminal === 'true'
    const incomingTerminal = incomingCard.dataset.receiptCardTerminal === 'true'

    return currentTerminal && !incomingTerminal
  }

  numericData (value) {
    const number = Number(value)

    return Number.isFinite(number) ? number : 0
  }

  nextPollInterval () {
    if (this.completedPollCount < this.fastPollLimitValue) return this.intervalValue

    return this.slowIntervalValue
  }

  nextPollDelay () {
    const delay = this.retryAfterMilliseconds || this.nextPollInterval()
    this.retryAfterMilliseconds = null

    return delay
  }

  retryDelay (response) {
    const retryAfterSeconds = Number(response.headers.get('Retry-After'))
    if (!Number.isFinite(retryAfterSeconds) || retryAfterSeconds <= 0) return this.slowIntervalValue

    return Math.max(retryAfterSeconds * 1000, this.slowIntervalValue)
  }

  networkOffline () {
    return window.navigator?.onLine === false
  }

  reportSyncFailure () {
    if (this.syncFailureReported) return

    this.syncFailureReported = true
    console.warn('[ReceiptProcessingSync] sync failed')
  }
}
