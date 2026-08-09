# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "rails_helper"

RSpec.describe "Mobile UI Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/mobile_ui_controller.js").read }

  def run_controller_script(script)
    controller_source = source.sub("import { Controller } from '@hotwired/stimulus'\n", "")
    encoded_source = Base64.strict_encode64(controller_source)
    harness = <<~JAVASCRIPT
      class Controller {}
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace('export default class extends Controller', 'class MobileUiController extends Controller')
      eval(`${source}\nglobalThis.MobileUiController = MobileUiController`)

      class FakeClassList {
        constructor () { this.names = new Set() }
        add (...names) { names.forEach((name) => this.names.add(name)) }
        remove (...names) { names.forEach((name) => this.names.delete(name)) }
        contains (name) { return this.names.has(name) }
      }

      class FakeElement {
        constructor () {
          this.attributes = new Map()
          this.classList = new FakeClassList()
        }
        toggleAttribute (name, force) {
          if (force) this.attributes.set(name, '')
          else this.attributes.delete(name)
        }
        setAttribute (name, value) { this.attributes.set(name, String(value)) }
        removeAttribute (name) { this.attributes.delete(name) }
        hasAttribute (name) { return this.attributes.has(name) }
      }

      globalThis.HTMLInputElement = class HTMLInputElement {}
      globalThis.HTMLTextAreaElement = class HTMLTextAreaElement {}
      globalThis.HTMLSelectElement = class HTMLSelectElement {}

      const listeners = { document: new Map(), window: new Map(), viewport: new Map() }
      const timers = new Map()
      let nextTimerId = 1
      const visualViewport = {
        height: 844,
        offsetTop: 0,
        addEventListener: (name, listener) => listeners.viewport.set(name, listener),
        removeEventListener: (name, listener) => {
          if (listeners.viewport.get(name) === listener) listeners.viewport.delete(name)
        }
      }
      globalThis.document = {
        addEventListener: (name, listener) => listeners.document.set(name, listener),
        removeEventListener: (name, listener) => {
          if (listeners.document.get(name) === listener) listeners.document.delete(name)
        }
      }
      globalThis.window = {
        innerWidth: 390,
        innerHeight: 844,
        visualViewport,
        addEventListener: (name, listener) => listeners.window.set(name, listener),
        removeEventListener: (name, listener) => {
          if (listeners.window.get(name) === listener) listeners.window.delete(name)
        },
        setTimeout: (callback) => {
          const id = nextTimerId++
          timers.set(id, callback)
          return id
        },
        clearTimeout: (id) => timers.delete(id)
      }

      const runTimers = () => {
        const callbacks = Array.from(timers.values())
        timers.clear()
        callbacks.forEach((callback) => callback())
      }
      const element = new FakeElement()
      const nav = new FakeElement()
      const notifications = []
      const controller = Object.create(MobileUiController.prototype)
      Object.assign(controller, {
        element,
        navTarget: nav,
        hasNavTarget: true,
        dispatch: (_name, options) => notifications.push(options.detail)
      })

      ;(async () => {
        #{script}
      })().catch((error) => {
        process.stderr.write(`${error.stack || error}\n`)
        process.exit(1)
      })
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "software keyboard stateだけで下部navigationを切り替えて金額サマリーへ通知する" do
    aggregate_failures do
      expect(source).to include("static targets = ['nav']")
      expect(source).to include("this.dispatch('keyboard-visibility-change'")
      expect(source).to include("turbo:before-cache")
      expect(source).to include("this.hideNav()")
      expect(source).to include("this.showNav()")
      expect(source).to include("this.navTarget.toggleAttribute('inert', true)")
      expect(source).to include("this.navTarget.setAttribute('aria-hidden', 'true')")
      expect(source).to include("this.navTarget.toggleAttribute('inert', false)")
      expect(source).to include("this.navTarget.removeAttribute('aria-hidden')")
      expect(source).to include("this.element.classList.add('pointer-events-none')")
      expect(source).to include("this.element.classList.remove('pointer-events-none')")
      expect(source).to include("window.visualViewport?.addEventListener('scroll', this.handleViewportResize)")
      expect(source).to include("window.visualViewport?.removeEventListener('scroll', this.handleViewportResize)")
      expect(source).not_to include("actionsTarget")
      expect(source).not_to include("hasActionsTarget")
      expect(source).not_to include("handleScroll")
      expect(source).not_to include("window.addEventListener('scroll'")
    end
  end

  it "focusが残っていてもsoftware keyboardが閉じたらnavigationを復帰する" do
    result = run_controller_script(<<~JAVASCRIPT)
      const snapshot = () => ({
        navHidden: nav.hasAttribute('inert'),
        rootBlocksPointer: element.classList.contains('pointer-events-none'),
        notification: notifications.at(-1) || null,
        notificationCount: notifications.length,
        timers: timers.size,
        baselineHeight: controller.initialViewportHeight,
        baselineWidth: controller.initialViewportWidth
      })

      controller.connect()
      const input = new HTMLInputElement()
      controller.handleFocusIn({ target: input })
      const focusPending = snapshot()

      const progressiveShrink = [800, 760, 700, 600].map((height) => {
        visualViewport.height = height
        controller.handleViewportResize()
        return snapshot()
      })
      const keyboardOpen = snapshot()

      visualViewport.height = 844
      controller.handleViewportResize()
      const keyboardClosedWithFocus = snapshot()

      controller.handleFocusIn({ target: input })
      runTimers()
      const physicalKeyboard = snapshot()

      window.innerWidth = 844
      window.innerHeight = 390
      visualViewport.height = 390
      controller.handleViewportResize()
      const physicalKeyboardAfterRotation = snapshot()

      window.innerWidth = 390
      window.innerHeight = 844
      visualViewport.height = 844
      controller.handleViewportResize()
      visualViewport.height = 544
      controller.handleViewportResize()

      window.innerWidth = 844
      window.innerHeight = 390
      visualViewport.height = 240
      controller.handleViewportResize()
      const softwareKeyboardAfterRotation = snapshot()

      visualViewport.offsetTop = 30
      listeners.viewport.get('scroll')()
      const softwareKeyboardAfterViewportScroll = snapshot()
      visualViewport.offsetTop = 0

      window.innerWidth = 390
      window.innerHeight = 844
      visualViewport.height = 844
      controller.handleViewportResize()
      const keyboardCloseDuringRotationPending = snapshot()
      controller.handleFocusOut({ target: input })
      const nextInput = new HTMLInputElement()
      controller.handleFocusIn({ target: nextInput })
      const rotationPendingAfterFocusTransfer = snapshot()
      runTimers()
      const keyboardClosedDuringRotation = snapshot()

      controller.handleBeforeCache()
      const beforeCache = snapshot()
      controller.disconnect()

      process.stdout.write(JSON.stringify({
        focusPending,
        progressiveShrink,
        keyboardOpen,
        keyboardClosedWithFocus,
        physicalKeyboard,
        physicalKeyboardAfterRotation,
        softwareKeyboardAfterRotation,
        softwareKeyboardAfterViewportScroll,
        keyboardCloseDuringRotationPending,
        rotationPendingAfterFocusTransfer,
        keyboardClosedDuringRotation,
        beforeCache,
        listenerCounts: {
          document: listeners.document.size,
          window: listeners.window.size,
          viewport: listeners.viewport.size,
          timers: timers.size
        }
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["focusPending"]).to include(
        "navHidden" => false,
        "rootBlocksPointer" => false,
        "notification" => nil,
        "notificationCount" => 0,
        "timers" => 1
      )
      expect(result["keyboardOpen"]).to include(
        "navHidden" => true,
        "notification" => { "visible" => true, "inset" => 244 }
      )
      expect(result["progressiveShrink"].map { |snapshot| snapshot.fetch("navHidden") }).to eq(
        [ false, false, true, true ]
      )
      expect(result["progressiveShrink"].map { |snapshot| snapshot.fetch("rootBlocksPointer") }).to eq(
        [ false, false, true, true ]
      )
      expect(result["keyboardClosedWithFocus"]).to include(
        "navHidden" => false,
        "rootBlocksPointer" => false,
        "notification" => { "visible" => false, "inset" => 0 }
      )
      expect(result["physicalKeyboard"]).to include(
        "navHidden" => false,
        "notification" => { "visible" => false, "inset" => 0 }
      )
      expect(result["physicalKeyboardAfterRotation"]).to include(
        "navHidden" => false,
        "rootBlocksPointer" => false,
        "notification" => { "visible" => false, "inset" => 0 },
        "baselineHeight" => 390,
        "baselineWidth" => 844
      )
      expect(result["softwareKeyboardAfterRotation"]).to include(
        "navHidden" => true,
        "rootBlocksPointer" => true,
        "notification" => { "visible" => true, "inset" => 150 },
        "baselineHeight" => 390,
        "baselineWidth" => 844
      )
      expect(result["softwareKeyboardAfterViewportScroll"]).to include(
        "navHidden" => true,
        "notification" => { "visible" => true, "inset" => 120 }
      )
      expect(result["keyboardCloseDuringRotationPending"]).to include(
        "navHidden" => true,
        "notification" => { "visible" => true, "inset" => 0 },
        "timers" => 1
      )
      expect(result["rotationPendingAfterFocusTransfer"]).to include(
        "navHidden" => true,
        "notification" => { "visible" => true, "inset" => 0 },
        "timers" => 1
      )
      expect(result["keyboardClosedDuringRotation"]).to include(
        "navHidden" => false,
        "rootBlocksPointer" => false,
        "notification" => { "visible" => false, "inset" => 0 },
        "baselineHeight" => 844,
        "baselineWidth" => 390
      )
      expect(result["beforeCache"]).to include(
        "navHidden" => false,
        "timers" => 0
      )
      expect(result["listenerCounts"]).to eq(
        "document" => 0,
        "window" => 0,
        "viewport" => 0,
        "timers" => 0
      )
    end
  end
end
