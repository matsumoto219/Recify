// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import '@hotwired/turbo-rails'
import 'controllers'

const syncThemePreference = () => {
  const themePreference = document.body?.dataset?.themePreference

  if (!themePreference) return

  document.documentElement.dataset.theme = themePreference
}

document.addEventListener('turbo:load', syncThemePreference)
