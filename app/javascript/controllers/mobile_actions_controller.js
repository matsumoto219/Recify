// app/javascript/controllers/mobile_actions_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["bar"]

  connect() {
    this.lastScrollY = window.scrollY
    this.threshold = 10

    this.handleScroll = this.handleScroll.bind(this)
    window.addEventListener("scroll", this.handleScroll)
  }

  disconnect() {
    window.removeEventListener("scroll", this.handleScroll)
  }

  handleScroll() {
    const currentScrollY = window.scrollY

    // 小さいスクロールは無視
    if (Math.abs(currentScrollY - this.lastScrollY) < this.threshold) return

    // 上部では常に表示
    if (currentScrollY < 50) {
      this.show()
      this.lastScrollY = currentScrollY
      return
    }

    if (currentScrollY > this.lastScrollY) {
      // 下スクロール → 表示
      this.show()
    } else {
      // 上スクロール → 非表示
      this.hide()
    }

    this.lastScrollY = currentScrollY
  }

  show() {
    this.barTarget.classList.remove("translate-y-full")
  }

  hide() {
    this.barTarget.classList.add("translate-y-full")
  }
}
