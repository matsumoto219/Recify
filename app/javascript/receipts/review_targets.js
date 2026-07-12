export const REVIEW_REASON_TARGET_LINK_SELECTOR = 'a[data-review-reason-target-link]'

export function reviewTargetUrl (href, baseHref) {
  try {
    return new URL(href || '', baseHref)
  } catch {
    return null
  }
}

export function samePageReviewTargetUrl (url, location) {
  return url.origin === location.origin &&
    url.pathname === location.pathname &&
    url.search === location.search
}

export function reviewTargetIdFromHash (hash) {
  const targetId = String(hash || '').replace(/^#/, '')
  if (targetId === '') return null

  try {
    return decodeURIComponent(targetId)
  } catch {
    return targetId
  }
}

export function reviewTargetHash (targetId) {
  return `#${encodeURIComponent(targetId)}`
}
