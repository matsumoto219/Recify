import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="security-scroll"
export default class extends Controller {
  static values = {
    scrollToPassword: Boolean
  }

  connect() {
    if (!this.scrollToPasswordValue) return

    requestAnimationFrame(() => {
      setTimeout(() => {
        const section = document.getElementById("password")
        const input = document.getElementById("user_current_password")
        if (!section) return

        section.scrollIntoView({ behavior: "auto", block: "start" })
        if (input) {
          input.focus({ preventScroll: true })
        }
      }, 0)
    })
  }
}
