// app/javascript/controllers/mobile_ui_controller.js
import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['nav', 'actions']

  connect () {
    this.lastScrollY = window.scrollY
    this.threshold = 30
    this.scrollDelta = 0
    this.lastDirection = 0 // 1: down, -1: up
    this.keyboardThreshold = 100
    this.isFormFocused = false
    this.isKeyboardVisible = false
    this.initialViewportHeight = this.currentViewportHeight()

    this.handleScroll = this.handleScroll.bind(this)
    this.handleViewportResize = this.handleViewportResize.bind(this)
    this.handleFocusIn = this.handleFocusIn.bind(this)
    this.handleFocusOut = this.handleFocusOut.bind(this)

    window.addEventListener('scroll', this.handleScroll)
    window.addEventListener('focusin', this.handleFocusIn)
    window.addEventListener('focusout', this.handleFocusOut)
    window.visualViewport?.addEventListener('resize', this.handleViewportResize)
  }

  disconnect () {
    window.clearTimeout(this.actionsHideTimeout)

    window.removeEventListener('scroll', this.handleScroll)
    window.removeEventListener('focusin', this.handleFocusIn)
    window.removeEventListener('focusout', this.handleFocusOut)
    window.visualViewport?.removeEventListener('resize', this.handleViewportResize)
  }

  handleScroll () {
    if (this.isFormFocused || this.isKeyboardVisible) {
      this.hideNav()
      this.hideActions()
      this.lastScrollY = window.scrollY
      this.scrollDelta = 0
      return
    }

    const currentScrollY = window.scrollY
    const delta = currentScrollY - this.lastScrollY

    // 無視できる微小変化
    if (Math.abs(delta) < 1) return

    const direction = delta > 0 ? 1 : -1

    // 方向が変わったら蓄積リセット
    if (direction !== this.lastDirection) {
      this.scrollDelta = 0
    }

    this.scrollDelta += Math.abs(delta)

    // 上部では追加ボタンを常に表示
    if (currentScrollY < 50) {
      this.showActions()
      this.lastScrollY = currentScrollY
      this.lastDirection = direction
      this.scrollDelta = 0
      return
    }

    // 閾値未満なら何もしない（ゆとり）
    if (this.scrollDelta < this.threshold) {
      this.lastScrollY = currentScrollY
      this.lastDirection = direction
      return
    }

    if (direction === 1) {
      // 下スクロール → 追加ボタン表示
      this.showActions()
    } else {
      // 上スクロール → 追加ボタン非表示
      this.hideActions()
    }

    // トリガー後はリセットして連続トグルを防ぐ
    this.scrollDelta = 0
    this.lastScrollY = currentScrollY
    this.lastDirection = direction
  }

  handleViewportResize () {
    const currentHeight = this.currentViewportHeight()
    const heightDiff = this.initialViewportHeight - currentHeight

    this.isKeyboardVisible = this.isFormFocused && heightDiff > this.keyboardThreshold

    if (this.isKeyboardVisible) {
      this.hideNav()
      this.hideActions()
      return
    }

    this.initialViewportHeight = currentHeight

    if (!this.isFormFocused) {
      this.showNav()
    }
  }

  handleFocusIn (event) {
    if (!this.isFormControl(event.target)) return

    // visualViewport resize が遅れる端末向けの保険
    this.isFormFocused = true
    this.isKeyboardVisible = true
    this.hideNav()
    this.hideActions()
  }

  handleFocusOut (event) {
    if (!this.isFormControl(event.target)) return

    this.isFormFocused = false

    // キーボード収納アニメーション後に visualViewport の値を確認する
    window.setTimeout(() => {
      this.handleViewportResize()
    }, 150)
  }

  currentViewportHeight () {
    return window.visualViewport?.height || window.innerHeight
  }

  isFormControl (element) {
    return element instanceof HTMLInputElement ||
      element instanceof HTMLTextAreaElement ||
      element instanceof HTMLSelectElement
  }

  showNav () {
    if (!this.hasNavTarget) return

    this.navTarget.classList.remove('translate-y-full', 'opacity-0', 'pointer-events-none')
  }

  hideNav () {
    if (!this.hasNavTarget) return

    this.navTarget.classList.add('translate-y-full', 'opacity-0', 'pointer-events-none')
  }

  showActions () {
    if (!this.hasActionsTarget) return

    window.clearTimeout(this.actionsHideTimeout)

    // 先に表示状態へ戻す
    this.actionsTarget.classList.remove('opacity-0', 'pointer-events-none')

    // 次フレームで下からスライドイン
    window.requestAnimationFrame(() => {
      this.actionsTarget.classList.remove('translate-y-full')
    })
  }

  hideActions () {
    if (!this.hasActionsTarget) return

    window.clearTimeout(this.actionsHideTimeout)

    // 先に下へスライドアウト
    this.actionsTarget.classList.add('translate-y-full', 'pointer-events-none')

    // 完全に下がってから透明化（Safari/iOSのちらつき対策）
    this.actionsHideTimeout = window.setTimeout(() => {
      this.actionsTarget.classList.add('opacity-0')
    }, 300)
  }
}
