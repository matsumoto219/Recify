import { Controller } from '@hotwired/stimulus'

// Handles settings-page-specific UI reactions after settings are saved.
export default class extends Controller {
  applySegmentedControlSetting (event) {
    const { name, value } = event.detail

    if (name === 'theme_preference') {
      this.applyTheme(value)
    }
  }

  restoreSegmentedControlSetting (event) {
    const { name, previousValue } = event.detail

    if (name === 'theme_preference') {
      this.applyTheme(previousValue)
    }
  }

  applyTheme (value) {
    document.documentElement.dataset.theme = value
    window.dispatchEvent(new CustomEvent('recify:theme-change'))
  }
}
