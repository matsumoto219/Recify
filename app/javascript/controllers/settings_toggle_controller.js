import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static targets = ["checkbox", "hidden", "track", "thumb"]
  static values = {
    url: String,
    name: String,
    checked: Boolean
  }

  connect() {
    this.isLoading = false
    this.syncFromValue()
  }

  toggle() {
    if (this.isLoading) return
    const nextChecked = !this.checkedValue
    this.checkedValue = nextChecked
    this.syncFromValue()
    this.startLoading()
    this.save()
  }

  syncFromValue() {
    if (this.hasCheckboxTarget) {
      this.checkboxTarget.checked = this.checkedValue
    }

    if (this.hasHiddenTarget) {
      this.hiddenTarget.value = this.checkedValue ? "1" : "0"
    }

    if (this.hasTrackTarget) {
      this.trackTarget.classList.toggle("bg-[#C0C1FF]/20", this.checkedValue)
      this.trackTarget.classList.toggle("border-[#C0C1FF]/40", this.checkedValue)
      this.trackTarget.classList.toggle("bg-[#353534]", !this.checkedValue)
      this.trackTarget.classList.toggle("border-white/10", !this.checkedValue)
    }

    if (this.hasThumbTarget) {
      this.thumbTarget.classList.toggle("left-6", this.checkedValue)
      this.thumbTarget.classList.toggle("bg-[#C0C1FF]", this.checkedValue)
      this.thumbTarget.classList.toggle("left-1", !this.checkedValue)
      this.thumbTarget.classList.toggle("bg-[#918FA1]", !this.checkedValue)
    }
  }

  async save() {
    const token = document.querySelector('meta[name="csrf-token"]')?.content

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": token,
          "Accept": "text/vnd.turbo-stream.html"
        },
        body: JSON.stringify({
          user: {
            [this.nameValue]: this.checkedValue
          }
        })
      })

      const responseBody = await response.text()

      if (responseBody.length > 0) {
        Turbo.renderStreamMessage(responseBody)
      }

      if (!response.ok) {
        this.checkedValue = !this.checkedValue
        this.syncFromValue()
      }
    } catch (_error) {
      this.checkedValue = !this.checkedValue
      this.syncFromValue()
    } finally {
      this.stopLoading()
    }
  }
  startLoading() {
    this.isLoading = true
    if (this.hasTrackTarget) {
      this.trackTarget.classList.add("opacity-60", "pointer-events-none")
    }
  }

  stopLoading() {
    this.isLoading = false
    if (this.hasTrackTarget) {
      this.trackTarget.classList.remove("opacity-60", "pointer-events-none")
    }
  }
}
