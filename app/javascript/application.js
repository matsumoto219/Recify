// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import '@hotwired/turbo-rails'
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

const systemThemeMedia = window.matchMedia?.('(prefers-color-scheme: dark)')

document.addEventListener('turbo:load', syncTheme)
window.addEventListener('recify:theme-change', syncBrowserChromeThemeColor)
systemThemeMedia?.addEventListener('change', syncBrowserChromeThemeColor)
