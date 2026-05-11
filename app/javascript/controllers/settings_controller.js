import { Controller } from '@hotwired/stimulus'

// Handles settings-page-specific UI reactions after settings are saved.
export default class extends Controller {
  applySegmentedControlSetting (event) {
    const { name, value } = event.detail

    if (name === 'theme_preference') {
      this.applyTheme(value)
    }
  }

  applyTheme (value) {
    document.documentElement.dataset.theme = value
  }
}
