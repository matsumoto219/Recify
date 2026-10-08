// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import '@hotwired/turbo-rails'
import 'confirm_method'
import 'controllers'

const syncThemePreference = () => {
  const themePreference = document.body?.dataset?.themePreference

  if (!themePreference) return

  document.documentElement.dataset.theme = themePreference
}

const resolveCssColor = (value) => {
  const host = document.body || document.documentElement

  if (!host) return ''

  const probe = document.createElement('span')
  probe.style.position = 'absolute'
  probe.style.visibility = 'hidden'
  probe.style.pointerEvents = 'none'
  probe.style.backgroundColor = value

  host.appendChild(probe)
  const resolvedColor = window.getComputedStyle(probe).backgroundColor
  probe.remove()

  return resolvedColor
}

const syncBrowserChromeThemeColor = () => {
  const meta = document.querySelector('meta[data-browser-chrome-theme-color]')

  if (!meta) return

  const resolvedColor = resolveCssColor('var(--browser-chrome-bg)')

  if (!resolvedColor) return

  meta.setAttribute('content', resolvedColor)
}

const syncTheme = () => {
  syncThemePreference()
  syncBrowserChromeThemeColor()
}

const restorePreviewSources = (event) => {
  // Cached bodies may reference object URLs released by the previous controllers.
  // Restore safe sources before insertion; connect can rebuild any retained File.
  event.detail.newBody.querySelectorAll('img[data-persisted-url][src^="blob:"]').forEach((image) => {
    const source = image.dataset.persistedUrl
    if (source) {
      image.setAttribute('src', source)
    } else {
      image.removeAttribute('src')
    }
  })
}

const systemThemeMedia = window.matchMedia?.('(prefers-color-scheme: dark)')

document.addEventListener('turbo:before-render', restorePreviewSources)
document.addEventListener('turbo:load', syncTheme)
window.addEventListener('recify:theme-change', syncBrowserChromeThemeColor)
systemThemeMedia?.addEventListener('change', syncBrowserChromeThemeColor)
