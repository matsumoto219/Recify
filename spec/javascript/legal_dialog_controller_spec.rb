# frozen_string_literal: true

require "base64"
require "json"
require "open3"

RSpec.describe "Legal dialog Stimulus controller" do
  let(:source) { File.read(File.expand_path("../../app/javascript/controllers/legal_dialog_controller.js", __dir__)) }

  def run_controller_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class LegalDialogController extends Controller')

      eval(`${source}\nglobalThis.LegalDialogController = LegalDialogController`)

      globalThis.document = { body: { style: { overflow: 'auto' } }, activeElement: null }
      globalThis.window = { getComputedStyle: () => ({ display: 'block', visibility: 'visible' }) }
      globalThis.requestAnimationFrame = (callback) => callback()

      const makeElement = (name) => ({
        name,
        isConnected: true,
        focus () { document.activeElement = this },
        hasAttribute: () => false,
        getAttribute: () => null
      })
      const trigger = makeElement('trigger')
      const input = makeElement('input')
      const closeButton = makeElement('close button')
      let previouslyFocusedElement
      const dialog = {
        ...makeElement('dialog'),
        dataset: { legalDialogName: 'terms' },
        open: false,
        closest: () => dialog,
        querySelectorAll: () => [closeButton],
        showModal () {
          previouslyFocusedElement = document.activeElement
          this.open = true
        },
        close () {
          this.open = false
          previouslyFocusedElement.focus()
        }
      }
      closeButton.closest = () => dialog
      const controller = Object.create(LegalDialogController.prototype)
      Object.assign(controller, { dialogTargets: [dialog] })
      controller.connect()
      trigger.focus()
      controller.open({
        params: { dialog: 'terms' },
        currentTarget: trigger,
        preventDefault: () => {}
      })

      #{script}
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "閉じるとcloseイベントを待たずにフォーカスとスクロール設定を復元する" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.close({ currentTarget: closeButton, preventDefault: () => {} })

      process.stdout.write(JSON.stringify({
        open: dialog.open,
        focus: document.activeElement.name,
        overflow: document.body.style.overflow
      }))
    JAVASCRIPT

    expect(result).to eq("open" => false, "focus" => "trigger", "overflow" => "auto")
  end

  it "閉じた後のcloseイベントで次の入力欄からフォーカスを奪わない" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.close({ currentTarget: closeButton, preventDefault: () => {} })
      input.focus()
      controller.handleClose({ target: dialog })

      process.stdout.write(JSON.stringify({
        focus: document.activeElement.name,
        overflow: document.body.style.overflow
      }))
    JAVASCRIPT

    expect(result).to eq("focus" => "input", "overflow" => "auto")
  end

  it "ブラウザのcancelで閉じた後も次の入力欄のフォーカスを維持する" do
    result = run_controller_script(<<~JAVASCRIPT)
      let prevented = false
      controller.handleCancel({
        target: dialog,
        currentTarget: dialog,
        preventDefault: () => { prevented = true }
      })
      if (!prevented) dialog.close()
      input.focus()
      controller.handleClose({ target: dialog })

      process.stdout.write(JSON.stringify({
        focus: document.activeElement.name,
        overflow: document.body.style.overflow
      }))
    JAVASCRIPT

    expect(result).to eq("focus" => "input", "overflow" => "auto")
  end

  it "再表示したダイアログへ古いcloseイベントが届いても操作を維持する" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.close({ currentTarget: closeButton, preventDefault: () => {} })
      controller.open({
        params: { dialog: 'terms' },
        currentTarget: trigger,
        preventDefault: () => {}
      })
      controller.handleClose({ target: dialog })

      process.stdout.write(JSON.stringify({
        open: dialog.open,
        focus: document.activeElement.name,
        overflow: document.body.style.overflow
      }))
    JAVASCRIPT

    expect(result).to eq("open" => true, "focus" => "close button", "overflow" => "hidden")
  end

  it "切断時に閉じた後のcloseイベントで移動先からフォーカスを奪わない" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.disconnect()
      input.focus()
      controller.handleClose({ target: dialog })

      process.stdout.write(JSON.stringify({
        open: dialog.open,
        focus: document.activeElement.name,
        overflow: document.body.style.overflow
      }))
    JAVASCRIPT

    expect(result).to eq("open" => false, "focus" => "input", "overflow" => "auto")
  end
end
