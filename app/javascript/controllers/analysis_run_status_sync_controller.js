import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['row']
  static values = {
    url: String,
    interval: { type: Number, default: 5000 }
  }

  connect () {
    this.connected = true
    this.pollTimer = null
    this.immediateTimer = null
    this.abortController = null
    this.syncInFlight = false
    this.pollingPaused = false

    this.handleBeforeCache = this.handleBeforeCache.bind(this)
    this.handleVisibilityChange = this.handleVisibilityChange.bind(this)
    this.handleOnline = this.handleOnline.bind(this)

    document.addEventListener('turbo:before-cache', this.handleBeforeCache)
    document.addEventListener('visibilitychange', this.handleVisibilityChange)
    window.addEventListener('online', this.handleOnline)

    this.queueImmediateSync()
  }

  disconnect () {
    this.connected = false
    document.removeEventListener('turbo:before-cache', this.handleBeforeCache)
    document.removeEventListener('visibilitychange', this.handleVisibilityChange)
    window.removeEventListener('online', this.handleOnline)
    this.stopPolling({ abort: true })
  }

  rowTargetConnected () {
    this.queueImmediateSync()
  }

  rowTargetDisconnected () {
    if (this.activeRows().length === 0) this.clearPollTimer()
  }

  handleBeforeCache () {
    this.pollingPaused = true
    this.stopPolling({ abort: true })
  }

  handleVisibilityChange () {
    if (document.visibilityState === 'hidden') {
      this.pollingPaused = true
      this.stopPolling({ abort: true })
      return
    }

    this.pollingPaused = false
    this.queueImmediateSync()
  }

  handleOnline () {
    this.queueImmediateSync()
  }

  queueImmediateSync () {
    if (!this.connected || this.pollingPaused || document.visibilityState === 'hidden') return
    if (this.activeRows().length === 0 || this.syncInFlight) return

    this.clearImmediateTimer()
    this.immediateTimer = window.setTimeout(() => {
      this.immediateTimer = null
      this.syncNow()
    }, 0)
  }

  async syncNow () {
    if (!this.connected || this.pollingPaused || document.visibilityState === 'hidden' || this.syncInFlight) return

    const rows = this.activeRows()
    if (rows.length === 0) {
      this.clearPollTimer()
      return
    }

    this.clearPollTimer()
    this.syncInFlight = true
    const controller = new AbortController()
    this.abortController = controller

    try {
      const url = new URL(this.urlValue, window.location.origin)
      rows.forEach((row) => url.searchParams.append('run_keys[]', row.dataset.analysisRunStatusSyncRunKey))

      const response = await window.fetch(url, {
        method: 'GET',
        headers: {
          Accept: 'application/json',
          'X-Requested-With': 'XMLHttpRequest'
        },
        credentials: 'same-origin',
        cache: 'no-store',
        signal: controller.signal
      })
      if (!response.ok) return

      this.applyPayload(await response.json())
    } catch (error) {
      if (error.name !== 'AbortError') console.warn('[AnalysisRunStatusSync] sync failed')
    } finally {
      if (this.abortController === controller) this.abortController = null
      this.syncInFlight = false
      this.scheduleNextPoll()
    }
  }

  applyPayload (payload) {
    const states = Array.isArray(payload?.runs) ? payload.runs : []
    const statesByRunKey = new Map(states.map((state) => [state.run_key, state]))

    this.activeRows().forEach((row) => {
      const state = statesByRunKey.get(row.dataset.analysisRunStatusSyncRunKey)
      if (!state) return
      if (state.missing) {
        this.markTerminal(row)
        return
      }
      if (this.isOlderState(row, state)) return

      this.updateField(row, 'run_status', `${state.stage} / ${state.status}`)
      this.updateField(row, 'receipt_status', state.receipt_status)
      this.updateField(row, 'error_code', state.error_code || '-')
      row.dataset.analysisRunStatusSyncStateRevision = String(state.state_revision || 0)

      if (state.terminal) this.markTerminal(row)
    })
  }

  updateField (row, field, value) {
    row.querySelectorAll(`[data-analysis-run-status-sync-field="${field}"]`).forEach((element) => {
      element.textContent = value
    })
  }

  markTerminal (row) {
    row.dataset.analysisRunStatusSyncTerminal = 'true'
    row.removeAttribute('data-analysis-run-status-sync-target')
  }

  isOlderState (row, state) {
    const currentRevision = Number(row.dataset.analysisRunStatusSyncStateRevision || 0)
    const incomingRevision = Number(state.state_revision || 0)

    return incomingRevision < currentRevision
  }

  activeRows () {
    return this.rowTargets.filter((row) => row.dataset.analysisRunStatusSyncTerminal !== 'true')
  }

  scheduleNextPoll () {
    if (!this.connected || this.pollingPaused || document.visibilityState === 'hidden') return
    if (this.activeRows().length === 0) return

    this.clearPollTimer()
    this.pollTimer = window.setTimeout(() => {
      this.pollTimer = null
      this.syncNow()
    }, this.intervalValue)
  }

  stopPolling ({ abort = false } = {}) {
    this.clearImmediateTimer()
    this.clearPollTimer()

    if (abort && this.abortController) {
      this.abortController.abort()
      this.abortController = null
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
}
