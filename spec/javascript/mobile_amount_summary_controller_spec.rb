# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "rails_helper"

RSpec.describe "Mobile amount summary Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/mobile_amount_summary_controller.js").read }

  def run_controller_script(script)
    controller_source = source
      .sub("import { Controller } from '@hotwired/stimulus'\n", "")
      .sub(/import \{.*?\} from 'receipts\/review_targets'\n/m, "")
    encoded_source = Base64.strict_encode64(controller_source)
    harness = <<~JAVASCRIPT
      class Controller {}

      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace('export default class extends Controller', 'class MobileAmountSummaryController extends Controller')
      const REVIEW_REASON_TARGET_LINK_SELECTOR = 'a[data-review-reason-target-link]'
      const reviewTargetUrl = (href, baseHref) => {
        try { return new URL(href || '', baseHref) } catch { return null }
      }
      const samePageReviewTargetUrl = (url, location) =>
        url.origin === location.origin && url.pathname === location.pathname && url.search === location.search
      const reviewTargetIdFromHash = (hash) => {
        const targetId = String(hash || '').replace(/^#/, '')
        if (targetId === '') return null
        try { return decodeURIComponent(targetId) } catch { return targetId }
      }
      eval(`${source}\nglobalThis.MobileAmountSummaryController = MobileAmountSummaryController`)

      class FakeClassList {
        constructor (names = []) { this.names = new Set(names) }
        contains (name) { return this.names.has(name) }
        toggle (name, force) {
          if (force === undefined) force = !this.names.has(name)
          if (force) this.names.add(name)
          else this.names.delete(name)
          return force
        }
      }

      class FakeElement {
        constructor (classes = []) {
          this.attributes = new Map()
          this.classList = new FakeClassList(classes)
          this.dataset = {}
          this.rectHeight = 140
          this.style = {
            values: new Map(),
            getPropertyValue: (name) => this.style.values.get(name) || '',
            setProperty: (name, value) => this.style.values.set(name, value),
            removeProperty: (name) => this.style.values.delete(name)
          }
        }
        setAttribute (name, value) { this.attributes.set(name, String(value)) }
        getAttribute (name) { return this.attributes.get(name) }
        toggleAttribute (name, force) {
          if (force) this.attributes.set(name, '')
          else this.attributes.delete(name)
        }
        hasAttribute (name) { return this.attributes.has(name) }
        getBoundingClientRect () { return { height: this.rectHeight } }
      }

      const listeners = { document: new Map(), window: new Map() }
      const mediaQueries = new Map()
      const mediaFor = (query) => {
        if (mediaQueries.has(query)) return mediaQueries.get(query)

        const media = {
          matches: false,
          listener: null,
          addEventListener: (_name, listener) => { media.listener = listener },
          removeEventListener: (_name, listener) => {
            if (media.listener === listener) media.listener = null
          }
        }
        mediaQueries.set(query, media)
        return media
      }
      globalThis.document = {
        addEventListener: (name, listener) => listeners.document.set(name, listener),
        removeEventListener: (name, listener) => {
          if (listeners.document.get(name) === listener) listeners.document.delete(name)
        }
      }
      globalThis.window = {
        innerHeight: 844,
        location: {
          href: 'http://example.test/receipts/receipt_1/edit',
          origin: 'http://example.test',
          pathname: '/receipts/receipt_1/edit',
          search: '',
          hash: ''
        },
        matchMedia: (query) => mediaFor(query),
        addEventListener: (name, listener) => listeners.window.set(name, listener),
        removeEventListener: (name, listener) => {
          if (listeners.window.get(name) === listener) listeners.window.delete(name)
        },
        ResizeObserver: class {
          constructor (callback) {
            this.callback = callback
            this.observedElement = null
            this.disconnected = false
            resizeObservers.push(this)
          }
          observe (observedElement) { this.observedElement = observedElement }
          disconnect () { this.disconnected = true }
        }
      }

      const resizeObservers = []
      const details = new FakeElement(['collapsible-grid', 'is-open'])
      const toggle = new FakeElement()
      const icon = new FakeElement()
      const element = new FakeElement()
      const contentElement = new FakeElement()
      element.closest = (selector) => selector === '.receipt-form-content' ? contentElement : null
      const controller = Object.create(MobileAmountSummaryController.prototype)
      Object.assign(controller, {
        element,
        detailsTarget: details,
        toggleTarget: toggle,
        iconTarget: icon,
        openLabelValue: '金額の内訳を表示',
        closeLabelValue: '金額の内訳を閉じる',
        reviewTargetValue: 'receipt-section-amount-summary'
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

  it "phone、tablet、keyboard、desktop、Turbo cacheでARIAとinertを同期する" do
    result = run_controller_script(<<~JAVASCRIPT)
      const snapshot = () => ({
        open: details.classList.contains('is-open'),
        inert: details.hasAttribute('inert'),
        hidden: details.getAttribute('aria-hidden'),
        expanded: toggle.getAttribute('aria-expanded'),
        label: toggle.getAttribute('aria-label'),
        rotated: icon.classList.contains('rotate-180'),
        summaryOpen: element.classList.contains('receipt-amount-summary-details-open'),
        keyboard: element.dataset.mobileAmountSummaryKeyboardVisible,
        enhanced: element.dataset.mobileAmountSummaryEnhanced
      })

      controller.connect()
      const initialContentInset = contentElement.style.values.get('--receipt-mobile-amount-summary-height')
      const observedSummary = resizeObservers[0]?.observedElement === element
      element.rectHeight = 228.1
      resizeObservers[0]?.callback()
      const resizedContentInset = contentElement.style.values.get('--receipt-mobile-amount-summary-height')
      const mobileClosed = snapshot()

      controller.toggle({ preventDefault: () => {} })
      const mobileOpen = snapshot()

      controller.handleKeyboardVisibilityChange({ detail: { visible: true, inset: 314 } })
      const keyboardOpen = snapshot()
      const keyboardInset = element.style.values.get('--mobile-amount-keyboard-inset')

      controller.handleKeyboardVisibilityChange({ detail: { visible: false, inset: 0 } })
      const keyboardClosed = snapshot()

      controller.detailsMedia.matches = true
      controller.detailsMedia.listener()
      const tablet = snapshot()

      controller.handleKeyboardVisibilityChange({ detail: { visible: true, inset: 314 } })
      const tabletKeyboard = snapshot()
      controller.handleKeyboardVisibilityChange({ detail: { visible: false, inset: 0 } })
      const tabletRestored = snapshot()

      controller.desktopMedia.matches = true
      controller.desktopMedia.listener()
      const desktop = snapshot()

      controller.desktopMedia.matches = false
      controller.desktopMedia.listener()
      controller.detailsMedia.matches = false
      controller.detailsMedia.listener()
      const phoneAgain = snapshot()

      listeners.document.get('turbo:before-cache')()
      const beforeCache = snapshot()
      const contentInsetBeforeCache = contentElement.style.values.get('--receipt-mobile-amount-summary-height')
      const observerDisconnectedBeforeCache = resizeObservers[0]?.disconnected
      controller.disconnect()

      process.stdout.write(JSON.stringify({
        mobileClosed,
        initialContentInset,
        observedSummary,
        resizedContentInset,
        mobileOpen,
        keyboardOpen,
        keyboardInset,
        keyboardClosed,
        tablet,
        tabletKeyboard,
        tabletRestored,
        desktop,
        phoneAgain,
        beforeCache,
        contentInsetBeforeCache,
        observerDisconnectedBeforeCache,
        listenerCounts: {
          document: listeners.document.size,
          window: listeners.window.size,
          media: Array.from(mediaQueries.values()).filter((media) => media.listener !== null).length
        }
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["initialContentInset"]).to eq("140px")
      expect(result["observedSummary"]).to be(true)
      expect(result["resizedContentInset"]).to eq("229px")
      expect(result["contentInsetBeforeCache"]).to be_nil
      expect(result["observerDisconnectedBeforeCache"]).to be(true)
      expect(result["mobileClosed"]).to include(
        "open" => false,
        "inert" => true,
        "hidden" => "true",
        "expanded" => "false",
        "label" => "金額の内訳を表示",
        "rotated" => false,
        "summaryOpen" => false,
        "keyboard" => "false",
        "enhanced" => "true"
      )
      expect(result["mobileOpen"]).to include(
        "open" => true,
        "inert" => false,
        "hidden" => "false",
        "expanded" => "true",
        "label" => "金額の内訳を閉じる",
        "rotated" => true,
        "summaryOpen" => true
      )
      expect(result["keyboardOpen"]).to include(
        "open" => false,
        "keyboard" => "true"
      )
      expect(result["keyboardInset"]).to eq("314px")
      expect(result["keyboardClosed"]).to include(
        "open" => false,
        "keyboard" => "false"
      )
      expect(result["tablet"]).to include(
        "open" => true,
        "inert" => false,
        "hidden" => "false",
        "summaryOpen" => true
      )
      expect(result["tabletKeyboard"]).to include(
        "open" => false,
        "keyboard" => "true"
      )
      expect(result["tabletRestored"]).to include(
        "open" => true,
        "keyboard" => "false"
      )
      expect(result["desktop"]).to include(
        "open" => true,
        "inert" => false,
        "hidden" => "false"
      )
      expect(result["phoneAgain"]).to include(
        "open" => false,
        "inert" => true,
        "hidden" => "true"
      )
      expect(result["beforeCache"]).to include(
        "open" => true,
        "inert" => false,
        "hidden" => "false",
        "keyboard" => "false"
      )
      expect(result["beforeCache"]).not_to have_key("enhanced")
      expect(result["listenerCounts"]).to eq(
        "document" => 0,
        "window" => 0,
        "media" => 0
      )
    end
  end

  it "same-pageの金額確認リンクとdirect hashだけでmobile内訳を開く" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.connect()
      const targetLink = {
        getAttribute: () => '/receipts/receipt_1/edit#receipt-section-amount-summary'
      }
      controller.handleReviewTargetClick({
        target: { closest: () => targetLink }
      })
      const clickOpened = details.classList.contains('is-open')

      controller.setOpen(false)
      window.location.hash = '#receipt-section-amount-summary'
      listeners.window.get('hashchange')()
      const hashOpened = details.classList.contains('is-open')

      controller.setOpen(false)
      const foreignLink = {
        getAttribute: () => 'http://other.test/receipts/receipt_1/edit#receipt-section-amount-summary'
      }
      controller.handleReviewTargetClick({
        target: { closest: () => foreignLink }
      })
      const foreignOpened = details.classList.contains('is-open')

      element.dataset.mobileAmountSummaryKeyboardVisible = 'true'
      controller.handleReviewTargetClick({
        target: { closest: () => targetLink }
      })
      const keyboardOpened = details.classList.contains('is-open')
      controller.disconnect()

      process.stdout.write(JSON.stringify({ clickOpened, hashOpened, foreignOpened, keyboardOpened }))
    JAVASCRIPT

    expect(result).to eq(
      "clickOpened" => true,
      "hashOpened" => true,
      "foreignOpened" => false,
      "keyboardOpened" => false
    )
  end

  it "disconnect時にカード高の監視とフォーム余白を解除する" do
    result = run_controller_script(<<~JAVASCRIPT)
      controller.connect()
      const observer = resizeObservers[0]
      const insetBeforeDisconnect = contentElement.style.values.get('--receipt-mobile-amount-summary-height')
      controller.disconnect()

      process.stdout.write(JSON.stringify({
        insetBeforeDisconnect,
        insetAfterDisconnect: contentElement.style.values.get('--receipt-mobile-amount-summary-height'),
        observerDisconnected: observer.disconnected,
        listenerCounts: {
          document: listeners.document.size,
          window: listeners.window.size,
          media: Array.from(mediaQueries.values()).filter((media) => media.listener !== null).length
        }
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["insetBeforeDisconnect"]).to eq("140px")
      expect(result["insetAfterDisconnect"]).to be_nil
      expect(result["observerDisconnected"]).to be(true)
      expect(result["listenerCounts"]).to eq(
        "document" => 0,
        "window" => 0,
        "media" => 0
      )
    end
  end

  it "keyboardとbreakpointの通知順にかかわらず表示状態を維持する" do
    result = run_controller_script(<<~JAVASCRIPT)
      const snapshot = () => ({
        open: details.classList.contains('is-open'),
        keyboard: element.dataset.mobileAmountSummaryKeyboardVisible
      })

      controller.connect()
      controller.handleKeyboardVisibilityChange({ detail: { visible: true, inset: 314 } })
      controller.detailsMedia.matches = true
      controller.detailsMedia.listener()
      const keyboardThenTablet = snapshot()

      controller.handleKeyboardVisibilityChange({ detail: { visible: false, inset: 0 } })
      controller.detailsMedia.matches = false
      controller.detailsMedia.listener()
      controller.detailsMedia.matches = true
      controller.detailsMedia.listener()
      controller.handleKeyboardVisibilityChange({ detail: { visible: true, inset: 314 } })
      const tabletThenKeyboard = snapshot()

      controller.desktopMedia.matches = true
      controller.desktopMedia.listener()
      controller.desktopMedia.matches = false
      controller.desktopMedia.listener()
      const desktopKeyboardThenTablet = snapshot()

      controller.desktopMedia.matches = true
      controller.desktopMedia.listener()
      controller.handleKeyboardVisibilityChange({ detail: { visible: false, inset: 0 } })
      controller.desktopMedia.matches = false
      controller.desktopMedia.listener()
      const desktopKeyboardClosedThenTablet = snapshot()
      controller.disconnect()

      process.stdout.write(JSON.stringify({
        keyboardThenTablet,
        tabletThenKeyboard,
        desktopKeyboardThenTablet,
        desktopKeyboardClosedThenTablet
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["keyboardThenTablet"]).to eq("open" => false, "keyboard" => "true")
      expect(result["tabletThenKeyboard"]).to eq("open" => false, "keyboard" => "true")
      expect(result["desktopKeyboardThenTablet"]).to eq("open" => false, "keyboard" => "true")
      expect(result["desktopKeyboardClosedThenTablet"]).to eq("open" => true, "keyboard" => "false")
    end
  end

  it "MediaQueryListの旧Safari listener形式にもfallbackする" do
    aggregate_failures do
      expect(source).to include("this.desktopMedia.addListener(this.handleBreakpointChange)")
      expect(source).to include("this.desktopMedia?.removeListener(this.handleBreakpointChange)")
      expect(source).to include("this.detailsMedia.addListener(this.handleBreakpointChange)")
      expect(source).to include("this.detailsMedia?.removeListener(this.handleBreakpointChange)")
    end
  end
end
