import { Controller } from '@hotwired/stimulus'

// Controls the sliding indicator position for shared/ui/segmented_control.
export default class extends Controller {
  static targets = ['input']

  connect () {
    this.syncActiveIndex()
  }

  update (event) {
    const selectedInput = event.currentTarget
    const index = this.inputTargets.indexOf(selectedInput)

    if (index < 0) return

    this.setActiveIndex(index)
  }

  syncActiveIndex () {
    const checkedInput = this.inputTargets.find((input) => input.checked)
    const index = this.inputTargets.indexOf(checkedInput)

    this.setActiveIndex(index >= 0 ? index : 0)
  }

  setActiveIndex (index) {
    this.element.style.setProperty('--segmented-active-index', index)
  }
}
