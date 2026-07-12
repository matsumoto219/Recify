import { Controller } from '@hotwired/stimulus'

const EMAIL_DISPLAY_SELECTOR = '[data-email-address-display]'

export default class extends Controller {
  copy (event) {
    if (!event.clipboardData) return

    const display = this.fullySelectedEmailDisplay(document.getSelection())
    if (!display) return

    event.clipboardData.setData('text/plain', display.dataset.emailAddressValue)
    event.preventDefault()
  }

  fullySelectedEmailDisplay (selection) {
    if (!selection || selection.isCollapsed || selection.rangeCount !== 1) return null

    const anchorDisplay = this.emailDisplayFor(selection.anchorNode)
    const focusDisplay = this.emailDisplayFor(selection.focusNode)
    if (!anchorDisplay || anchorDisplay !== focusDisplay) return null

    const canonicalEmail = anchorDisplay.dataset.emailAddressValue
    if (!canonicalEmail || this.selectionText(selection) !== canonicalEmail) return null

    return anchorDisplay
  }

  emailDisplayFor (node) {
    const element = node?.nodeType === 1 ? node : node?.parentElement

    return element?.closest?.(EMAIL_DISPLAY_SELECTOR) || null
  }

  selectionText (selection) {
    return selection.toString().replace(/\s+/g, '')
  }
}
