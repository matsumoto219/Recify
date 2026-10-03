# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Tip Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/tip_controller.js").read }

  def run_controller_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class TipController extends Controller')

      eval(`${source}\nglobalThis.TipController = TipController`)
      const timers = new Map()
      let nextTimer = 0
      const target = () => ({
        listeners: new Map(),
        style: {},
        attributes: {},
        hidden: true,
        isConnected: true,
        addEventListener (name, handler) { this.listeners.set(name, handler) },
        removeEventListener (name) { this.listeners.delete(name) },
        setAttribute (name, value) { this.attributes[name] = value },
        contains (node) { return node === this },
        focus () { document.activeElement = this },
        remove () { this.removed = true },
        getBoundingClientRect () { return { left: 20, top: 20, right: 44, bottom: 44, width: 24, height: 24 } }
      })
      globalThis.document = Object.assign(target(), {
        activeElement: null,
        body: { appendChild (node) { node.parentElement = this } },
        createComment: () => Object.assign(target(), {
          parentNode: {},
          after (node) { node.parentElement = 'home' }
        })
      })
      globalThis.window = Object.assign(target(), {
        innerWidth: 390,
        innerHeight: 844,
        visualViewport: null,
        matchMedia: () => ({ matches: true }),
        setTimeout (callback, delay) {
          timers.set(++nextTimer, { callback, delay })
          return nextTimer
        },
        clearTimeout (id) { timers.delete(id) }
      })
      const trigger = target()
      const closeButton = target()
      const panel = Object.assign(target(), {
        before () {},
        querySelector: () => closeButton,
        contains (node) { return node === panel || node === closeButton },
        getBoundingClientRect () {
          return {
            width: Math.min(320, Number.parseFloat(this.style.maxWidth) || 320),
            height: Math.min(100, Number.parseFloat(this.style.maxHeight) || 100)
          }
        }
      })
      const controller = Object.create(TipController.prototype)
      Object.assign(controller, {
        element: target(),
        autoDismissValue: true,
        autoDismissDelayValue: 8000,
        closeOnOutsideValue: true
      })
      Object.defineProperties(controller, {
        triggerTarget: { value: trigger },
        panelTarget: { value: panel }
      })
      controller.connect()
      #{script}
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "opens on desktop hover without stealing focus and ignores touch hover" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.handlePointerEnter({ pointerType: 'touch' })
      const touchHidden = panel.hidden
      controller.handlePointerEnter({ pointerType: 'mouse' })
      process.stdout.write(JSON.stringify({
        touchHidden,
        hidden: panel.hidden,
        focused: document.activeElement !== null,
        portaled: panel.parentElement === document.body,
        expanded: trigger.attributes['aria-expanded']
      }))
    JAVASCRIPT

    expect(result).to eq(
      "touchHidden" => true,
      "hidden" => false,
      "focused" => false,
      "portaled" => true,
      "expanded" => "true"
    )
  end

  it "opens for a mouse when the primary input does not support hover and still ignores touch" do
    result = run_controller_script(<<~JAVASCRIPT)
      window.matchMedia = () => ({ matches: false })
      controller.handlePointerEnter({ pointerType: 'touch' })
      const touchHidden = panel.hidden
      controller.handlePointerEnter({ pointerType: 'pen' })
      const penHidden = panel.hidden
      controller.handlePointerEnter({ pointerType: 'mouse' })
      process.stdout.write(JSON.stringify({
        touchHidden,
        penHidden,
        hidden: panel.hidden,
        expanded: trigger.attributes['aria-expanded']
      }))
    JAVASCRIPT

    expect(result).to eq("touchHidden" => true, "penHidden" => true, "hidden" => false, "expanded" => "true")
  end

  it "pins a hovered tip on tap and closes it on a second tap" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.handlePointerEnter({ pointerType: 'mouse' })
      controller.toggle({ preventDefault () {}, detail: 1 })
      const pinnedOpen = !panel.hidden
      controller.toggle({ preventDefault () {}, detail: 1 })
      process.stdout.write(JSON.stringify({ pinnedOpen, hidden: panel.hidden, focused: document.activeElement === trigger }))
    JAVASCRIPT

    expect(result).to eq("pinnedOpen" => true, "hidden" => true, "focused" => true)
  end

  it "does not dismiss while the trigger is hovered and cancels a pending hover close on return" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.handlePointerEnter({ pointerType: 'mouse' })
      const hoveredWithoutTimer = timers.size === 0
      controller.handlePointerLeave({ relatedTarget: null })
      const pendingLeave = timers.size === 1
      controller.handlePointerEnter({ pointerType: 'mouse' })
      process.stdout.write(JSON.stringify({
        hoveredWithoutTimer,
        pendingLeave,
        returnedWithoutTimer: timers.size === 0,
        open: !panel.hidden
      }))
    JAVASCRIPT

    expect(result).to eq("hoveredWithoutTimer" => true, "pendingLeave" => true, "returnedWithoutTimer" => true, "open" => true)
  end

  it "resumes dismissal after keyboard focus leaves and never adds a timer when disabled" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.toggle({ preventDefault () {}, detail: 0 })
      const focusPaused = timers.size === 0
      controller.handleFocusOut({ relatedTarget: trigger })
      document.activeElement = trigger
      queueMicrotask(() => {
        const resumed = timers.size === 1
        controller.close()
        controller.autoDismissValue = false
        controller.toggle({ preventDefault () {}, detail: 1 })
        process.stdout.write(JSON.stringify({ focusPaused, resumed, disabledWithoutTimer: timers.size === 0 }))
      })
    JAVASCRIPT

    expect(result).to eq("focusPaused" => true, "resumed" => true, "disabledWithoutTimer" => true)
  end

  it "supports keyboard activation, close button, Escape and configurable outside dismissal" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.toggle({ preventDefault () {}, detail: 0 })
      const keyboardFocus = document.activeElement === panel
      controller.handleDocumentKeydown({ key: 'Escape', preventDefault () {} })
      const escaped = panel.hidden && document.activeElement === trigger
      controller.toggle({ preventDefault () {}, detail: 1 })
      controller.handleDocumentPointerDown({ target: closeButton })
      const insideOpen = !panel.hidden
      controller.closeOnOutsideValue = false
      controller.handleDocumentPointerDown({ target: {} })
      const outsideDisabledOpen = !panel.hidden
      controller.closeOnOutsideValue = true
      controller.handleDocumentPointerDown({ target: {} })
      const outsideClosed = panel.hidden
      controller.toggle({ preventDefault () {}, detail: 1 })
      closeButton.listeners.get('click')({ preventDefault () {} })
      process.stdout.write(JSON.stringify({
        keyboardFocus,
        escaped,
        insideOpen,
        outsideDisabledOpen,
        outsideClosed,
        buttonClosed: panel.hidden && document.activeElement === trigger
      }))
    JAVASCRIPT

    expect(result.values).to all(be(true))
  end

  it "pauses the timer during panel interaction and resumes after leaving" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.toggle({ preventDefault () {}, detail: 1 })
      controller.handlePanelPointerEnter({ pointerType: 'mouse' })
      const paused = timers.size === 0
      controller.handlePanelPointerLeave()
      const timer = Array.from(timers.values())[0]
      timer.callback()
      process.stdout.write(JSON.stringify({ paused, delay: timer.delay, closed: panel.hidden }))
    JAVASCRIPT

    expect(result).to eq("paused" => true, "delay" => 8000, "closed" => true)
  end

  it "keeps the tip inside visual viewport bounds at every edge including a short viewport" do
    result = run_controller_script(<<~JAVASCRIPT)
      window.visualViewport = Object.assign(target(), { offsetLeft: 30, offsetTop: 50, width: 190, height: 90 })
      trigger.getBoundingClientRect = () => ({ left: 190, top: 110, right: 214, bottom: 134, width: 24, height: 24 })
      controller.toggle({ preventDefault () {}, detail: 1 })
      const rect = panel.getBoundingClientRect()
      const left = Number.parseFloat(panel.style.left)
      const top = Number.parseFloat(panel.style.top)
      process.stdout.write(JSON.stringify({ inside: left >= 38 && top >= 58 && left + rect.width <= 212 && top + rect.height <= 132 }))
    JAVASCRIPT

    expect(result).to eq("inside" => true)
  end

  it "closes before Turbo caches and removes all relocated state on disconnect" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.toggle({ preventDefault () {}, detail: 1 })
      document.listeners.get('turbo:before-cache')()
      const cachedClosed = panel.hidden && panel.parentElement === 'home'
      controller.toggle({ preventDefault () {}, detail: 1 })
      controller.disconnect()
      process.stdout.write(JSON.stringify({
        cachedClosed,
        closed: panel.hidden,
        timers: timers.size,
        documentListeners: document.listeners.size,
        windowListeners: window.listeners.size,
        triggerListeners: trigger.listeners.size,
        closeListeners: closeButton.listeners.size
      }))
    JAVASCRIPT

    expect(result).to eq(
      "cachedClosed" => true,
      "closed" => true,
      "timers" => 0,
      "documentListeners" => 0,
      "windowListeners" => 0,
      "triggerListeners" => 0,
      "closeListeners" => 0
    )
  end

  it "preserves the panel in a detached subtree until Turbo clones its snapshot" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.toggle({ preventDefault () {}, detail: 1 })
      document.listeners.get('turbo:before-cache')()
      controller.placeholder.isConnected = false
      trigger.isConnected = false
      controller.disconnect()
      process.stdout.write(JSON.stringify({
        hidden: panel.hidden,
        home: panel.parentElement === 'home',
        removed: panel.removed === true,
        expanded: trigger.attributes['aria-expanded']
      }))
    JAVASCRIPT

    expect(result).to eq("hidden" => true, "home" => true, "removed" => false, "expanded" => "false")
  end

  it "removes a floating panel only when its original parent no longer exists" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.toggle({ preventDefault () {}, detail: 1 })
      controller.placeholder.isConnected = false
      controller.placeholder.parentNode = null
      controller.disconnect()
      process.stdout.write(JSON.stringify({ hidden: panel.hidden, removed: panel.removed === true, timers: timers.size }))
    JAVASCRIPT

    expect(result).to eq("hidden" => true, "removed" => true, "timers" => 0)
  end
end
