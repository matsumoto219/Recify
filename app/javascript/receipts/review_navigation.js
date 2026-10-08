import { reviewTargetHash } from 'receipts/review_targets'

const REVIEW_NAVIGATION_STATE_KEY = 'recifyReviewNavigation'
const reviewNavigationSessions = new WeakMap()

function reviewNavigationBase (location) {
  return `${location.origin}${location.pathname}${location.search}`
}

function reviewNavigationSupported (session) {
  return typeof session?.historyPoppedToLocationWithRestorationIdentifierAndDirection === 'function' &&
    typeof session.history?.push === 'function' &&
    typeof session.history?.getRestorationDataForIdentifier === 'function'
}

function reviewNavigationMarkerMatches (marker, formId, base) {
  return marker?.formId === formId && marker.base === base &&
    typeof marker.group === 'string' && marker.group !== ''
}

function reviewNavigationOwned (registration, location) {
  if (!registration || !location || !registration.form.isConnected) return false

  const { form, formId, base, marker, session } = registration
  const currentMarker = window.history.state?.[REVIEW_NAVIGATION_STATE_KEY]
  return session === window.Turbo?.session && session.enabled === true &&
    form.id === formId && document.getElementById(formId) === form &&
    reviewNavigationBase(location) === base && reviewNavigationBase(window.location) === base &&
    reviewNavigationMarkerMatches(currentMarker, formId, base) && currentMarker.group === marker.group
}

function reviewNavigationIdle (form) {
  return document.documentElement.getAttribute('aria-busy') !== 'true' &&
    form.getAttribute('aria-busy') !== 'true' &&
    !document.querySelector('form[aria-busy="true"]') &&
    !document.documentElement.hasAttribute('data-turbo-preview')
}

function installReviewNavigation (session) {
  const existing = reviewNavigationSessions.get(session)
  if (existing) return existing

  const original = session.historyPoppedToLocationWithRestorationIdentifierAndDirection
  const entry = { registration: null }
  entry.handler = function (...args) {
    const [location, restorationIdentifier] = args
    const registration = entry.registration
    if (this !== session || !reviewNavigationSupported(session) ||
      !reviewNavigationOwned(registration, location) || !reviewNavigationIdle(registration.form)) {
      return original.apply(this, args)
    }

    // Turbo normally restores scroll inside its restore Visit. Keep that position
    // for the hashless entry while preserving this form's current DOM and draft.
    if (!location.hash) {
      const position = session.history.getRestorationDataForIdentifier(restorationIdentifier)?.scrollPosition
      if (Number.isFinite(position?.x) && Number.isFinite(position?.y)) {
        window.scrollTo(position.x, position.y)
      } else {
        window.scrollTo(0, 0)
      }
    }
  }
  session.historyPoppedToLocationWithRestorationIdentifierAndDirection = entry.handler
  reviewNavigationSessions.set(session, entry)
  return entry
}

export function registerReviewNavigation (form) {
  if (typeof window === 'undefined') return null

  const session = window.Turbo?.session
  if (!reviewNavigationSupported(session) || !form?.isConnected || !form.id ||
    document.getElementById(form.id) !== form || typeof window.crypto?.randomUUID !== 'function') return null

  const base = reviewNavigationBase(window.location)
  const existingMarker = window.history.state?.[REVIEW_NAVIGATION_STATE_KEY]
  const marker = reviewNavigationMarkerMatches(existingMarker, form.id, base)
    ? existingMarker
    : { group: window.crypto.randomUUID(), formId: form.id, base }
  const entry = installReviewNavigation(session)
  if (session.historyPoppedToLocationWithRestorationIdentifierAndDirection !== entry.handler) return null

  const registration = { session, form, formId: form.id, base, marker }
  window.history.replaceState({ ...window.history.state, [REVIEW_NAVIGATION_STATE_KEY]: marker }, '', window.location.href)
  entry.registration = registration
  return registration
}

export function unregisterReviewNavigation (registration) {
  const entry = registration && reviewNavigationSessions.get(registration.session)
  if (entry && entry.registration === registration) entry.registration = null
}

export function navigateReviewTargetHash (targetId) {
  if (typeof window === 'undefined' || !targetId) return false

  const hash = reviewTargetHash(targetId)
  if (hash === window.location.hash || pushReviewNavigationHash(hash)) return true

  if (window.Turbo?.session?.enabled && typeof window.Turbo.visit === 'function') {
    const location = new URL(window.location.href)
    location.hash = hash
    window.Turbo.visit(location.href, { action: 'advance' })
    return false
  }

  window.location.hash = hash
  return true
}

export function pushReviewNavigationHash (hash) {
  if (typeof window === 'undefined') return false

  const session = window.Turbo?.session
  const entry = session && reviewNavigationSessions.get(session)
  const registration = entry?.registration
  if (!reviewNavigationSupported(session) ||
    session.historyPoppedToLocationWithRestorationIdentifierAndDirection !== entry?.handler ||
    !reviewNavigationOwned(registration, window.location)) return false
  if (hash === '' || hash === '#' || hash === window.location.hash) return true
  if (typeof hash !== 'string' || !hash.startsWith('#')) return false

  const location = new URL(window.location.href)
  location.hash = hash
  const previousState = window.history.state
  session.history.push(location)
  window.history.replaceState({
    ...previousState,
    ...window.history.state,
    [REVIEW_NAVIGATION_STATE_KEY]: registration.marker
  }, '', location.href)
  return true
}
