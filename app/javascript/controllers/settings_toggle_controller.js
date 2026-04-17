import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "hidden", "track", "thumb"]
  static values = {
    url: String,
    name: String,
    checked: Boolean
  }

  connect() {
    this.syncFromValue()
  }

  toggle() {
    const nextChecked = !this.checkedValue
    this.checkedValue = nextChecked
    this.syncFromValue()
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

    const response = await fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": token,
        "Accept": "application/json"
      },
      body: JSON.stringify({
        user: {
          [this.nameValue]: this.checkedValue
        }
      })
    })

    if (!response.ok) {
      this.checkedValue = !this.checkedValue
      this.syncFromValue()
    }
  }
}
