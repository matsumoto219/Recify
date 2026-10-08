# frozen_string_literal: true

require "base64"
require "json"
require "open3"

RSpec.describe "Receipt review navigation JavaScript module" do
  let(:browser_setup) do
    <<~JAVASCRIPT
      const makeElement = (id) => ({
        id, isConnected: true, attributes: {},
        getAttribute (name) { return this.attributes[name] ?? null },
        hasAttribute (name) { return Object.hasOwn(this.attributes, name) }
      })
      const form = makeElement('edit_receipt_1')
      const html = makeElement('html')
      let forms = [form]
      const calls = []
      const pushes = []
      const scrolls = []
      const entries = [{
        state: { turbo: { restorationIdentifier: 'initial', restorationIndex: 0 }, existing: { keep: true } },
        href: 'https://recify.example/receipts/1/edit?tab=items'
      }]
      let currentEntry = 0
      let group = 0
      globalThis.document = {
        documentElement: html,
        getElementById: (id) => forms.find((candidate) => candidate.isConnected && candidate.id === id) || null,
        querySelector: () => forms.find((candidate) => candidate.attributes['aria-busy'] === 'true') || null
      }
      globalThis.window = {
        location: new URL(entries[0].href),
        crypto: { randomUUID: () => 'group-' + ++group },
        scrollTo: (x, y) => scrolls.push({ x, y }),
        history: {
          get state () { return entries[currentEntry].state },
          replaceState (state, title, href) {
            entries[currentEntry] = { state: structuredClone(state), href }
            window.location = new URL(href)
          },
          pushState (state, title, href) {
            entries.splice(++currentEntry, entries.length, { state: structuredClone(state), href })
            window.location = new URL(href)
          }
        }
      }
      const session = {
        enabled: true,
        history: {
          currentIndex: 0,
          location: window.location,
          restorationIdentifier: 'initial',
          restorationData: {},
          push (location) {
            const restorationIdentifier = 'entry-' + ++this.currentIndex
            window.history.pushState({ turbo: { restorationIdentifier, restorationIndex: this.currentIndex } }, '', location.href)
            this.location = location
            this.restorationIdentifier = restorationIdentifier
            pushes.push(location.href)
          },
          getRestorationDataForIdentifier (identifier) { return this.restorationData[identifier] || {} }
        },
        historyPoppedToLocationWithRestorationIdentifierAndDirection (...args) {
          calls.push({ receiver: this, args })
          return 'delegated'
        }
      }
      window.Turbo = { session }
      const original = session.historyPoppedToLocationWithRestorationIdentifierAndDirection
      const popTo = (index) => {
        currentEntry = index
        window.location = new URL(entries[index].href)
        const { restorationIdentifier, restorationIndex } = window.history.state.turbo
        session.history.location = window.location
        session.history.restorationIdentifier = restorationIdentifier
        const direction = restorationIndex > session.history.currentIndex ? 'forward' : 'back'
        const result = session.historyPoppedToLocationWithRestorationIdentifierAndDirection(window.location, restorationIdentifier, direction)
        session.history.currentIndex = restorationIndex
        return result
      }
    JAVASCRIPT
  end

  def run_module_script(script)
    source = %w[review_targets review_navigation].map do |name|
      File.read(File.expand_path("../../app/javascript/receipts/#{name}.js", __dir__))
        .gsub(/^import .* from 'receipts\/review_targets'\n/, "")
        .gsub(/^export /, "")
    end.join("\n")
    encoded_source = Base64.strict_encode64("#{source}\n#{script}")
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
      eval(source)
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", stdin_data: harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  def run_form_navigation_script(script)
    source = File.read(File.expand_path("../../app/javascript/controllers/receipt_form_controller.js", __dir__))
      .gsub(/import \{[^}]*\} from '[^']+'\n/m, "")
      .sub("export default class extends Controller", "class ReceiptFormController extends Controller")

    run_module_script(browser_setup + <<~JAVASCRIPT + script)
      class Controller {}
      #{source}
      const target = {
        id: 'receipt-section-amount-summary',
        inside: true,
        isConnected: true,
        scrollIntoView: (options) => scrolls.push(options)
      }
      const link = {
        inside: true,
        dataset: { reviewReasonTarget: target.id },
        attributes: {},
        getAttribute (name) {
          return name === 'href' ? '#' + target.id : (this.attributes[name] ?? null)
        },
        hasAttribute (name) { return Object.hasOwn(this.attributes, name) },
        closest: () => link
      }
      const event = {
        target: link, button: 0, detail: 0, defaultPrevented: false,
        preventDefault () { this.defaultPrevented = true }
      }
      const reveals = []
      let scrollHandled = false
      form.contains = (node) => node?.inside === true
      form.dispatchEvent = (event) => {
        reveals.push({ type: event.type, ...event.detail })
        return !scrollHandled
      }
      const getElementById = document.getElementById
      document.getElementById = (id) => id === target.id ? target : getElementById(id)
      window.requestAnimationFrame = (callback) => callback()
      window.setTimeout = (callback) => { callback(); return 1 }
      window.clearTimeout = () => {}
      globalThis.CustomEvent = class {
        constructor (type, options) { this.type = type; Object.assign(this, options) }
      }
      const controller = Object.assign(Object.create(ReceiptFormController.prototype), {
        element: form,
        reviewItemTargetPrefixValue: 'receipt-item-',
        reviewItemsTargetValue: 'receipt-section-items',
        reviewAdjustmentTargetPrefixValue: 'receipt-adjustment-',
        reviewAdjustmentsTargetValue: 'receipt-section-adjustments'
      })
      registerReviewNavigation(form)
    JAVASCRIPT
  end

  %w[basic-info items adjustments payments amount-summary image-preview].each do |section|
    it "#{section}への確認リンクを同じformの履歴へ登録し再クリックでも履歴を重ねない" do
      result = run_form_navigation_script(<<~JAVASCRIPT)
        target.id = 'receipt-section-#{section}'
        link.dataset.reviewReasonTarget = target.id
        controller.handleReviewTargetClick(event)
        controller.handleReviewTargetClick({ ...event, defaultPrevented: false })
        process.stdout.write(JSON.stringify({
          prevented: event.defaultPrevented,
          pushes: pushes.length,
          hash: session.history.location.hash,
          identifier: session.history.restorationIdentifier,
          reveals,
          scrolls: scrolls.length
        }))
      JAVASCRIPT

      expect(result).to eq(
        "prevented" => true, "pushes" => 1, "hash" => "#receipt-section-#{section}",
        "identifier" => "entry-1",
        "reveals" => Array.new(2) { { "type" => "receipt-review:navigate", "targetId" => "receipt-section-#{section}" } },
        "scrolls" => 2
      )
    end
  end

  it "画像カードが展開後のスクロールを担当するとformは重複してスクロールしない" do
    result = run_form_navigation_script(<<~JAVASCRIPT)
      target.id = 'receipt-section-image-preview'
      link.dataset.reviewReasonTarget = target.id
      scrollHandled = true
      controller.handleReviewTargetClick(event)
      process.stdout.write(JSON.stringify({ reveals: reveals.length, pushes: pushes.length, scrolls: scrolls.length }))
    JAVASCRIPT

    expect(result).to eq("reveals" => 1, "pushes" => 1, "scrolls" => 0)
  end

  {
    "別formのリンク" => "link.inside = false",
    "別formの移動先" => "target.inside = false",
    "定義と異なる移動先" => "link.dataset.reviewReasonTarget = 'other-section'",
    "別origin" => "link.getAttribute = (name) => name === 'href' ? 'https://other.example/#' + target.id : null",
    "別path" => "link.getAttribute = (name) => name === 'href' ? '/receipts/2/edit#' + target.id : null",
    "別query" => "link.getAttribute = (name) => name === 'href' ? '?tab=other#' + target.id : null",
    "処理済みclick" => "event.defaultPrevented = true",
    "中ボタン" => "event.button = 1",
    "右ボタン" => "event.button = 2",
    "Meta click" => "event.metaKey = true",
    "Control click" => "event.ctrlKey = true",
    "Shift click" => "event.shiftKey = true",
    "Alt click" => "event.altKey = true",
    "別tab" => "link.attributes.target = '_blank'",
    "download" => "link.attributes.download = ''"
  }.each do |condition, setup|
    it "#{condition}を画面内の確認移動として横取りしない" do
      result = run_form_navigation_script(<<~JAVASCRIPT)
        #{setup}
        const initiallyPrevented = event.defaultPrevented
        controller.handleReviewTargetClick(event)
        process.stdout.write(JSON.stringify({
          prevented: event.defaultPrevented !== initiallyPrevented,
          pushes: pushes.length, reveals: reveals.length, scrolls: scrolls.length
        }))
      JAVASCRIPT

      expect(result).to eq("prevented" => false, "pushes" => 0, "reveals" => 0, "scrolls" => 0)
    end
  end

  it "Turbo内部APIが使えない確認移動は独自のstateを作らず通常のvisitへ戻す" do
    result = run_module_script(browser_setup + <<~JAVASCRIPT)
      const visits = []
      window.Turbo.visit = (...args) => visits.push(args)
      delete session.history.getRestorationDataForIdentifier
      const originalState = structuredClone(window.history.state)
      const handled = navigateReviewTargetHash('receipt-section-image-preview')
      process.stdout.write(JSON.stringify({ handled, visits, unchanged: JSON.stringify(window.history.state) === JSON.stringify(originalState) }))
    JAVASCRIPT

    expect(result).to eq(
      "handled" => false,
      "visits" => [ [ "https://recify.example/receipts/1/edit?tab=items#receipt-section-image-preview", { "action" => "advance" } ] ],
      "unchanged" => true
    )
  end

  it "Turboの履歴識別子とindexを更新し、既存stateを保持して同じform内を戻る" do
    result = run_module_script(browser_setup + <<~JAVASCRIPT)
      registerReviewNavigation(form)
      const initialGroup = window.history.state.recifyReviewNavigation.group
      const first = pushReviewNavigationHash('#receipt-adjustment-1')
      const second = pushReviewNavigationHash('#receipt-adjustment-2')
      popTo(1)
      process.stdout.write(JSON.stringify({
        first, second,
        pushes: pushes.length,
        delegated: calls.length,
        hash: session.history.location.hash,
        index: session.history.currentIndex,
        identifier: session.history.restorationIdentifier,
        existing: window.history.state.existing,
        sameGroup: window.history.state.recifyReviewNavigation.group === initialGroup
      }))
    JAVASCRIPT

    expect(result).to eq(
      "first" => true, "second" => true, "pushes" => 2, "delegated" => 0,
      "hash" => "#receipt-adjustment-1", "index" => 1, "identifier" => "entry-1",
      "existing" => { "keep" => true }, "sameGroup" => true
    )
  end

  it "hashのない初期履歴へ戻る際は保存済みスクロール位置を復元する" do
    result = run_module_script(browser_setup + <<~JAVASCRIPT)
      registerReviewNavigation(form)
      session.history.restorationData.initial = { scrollPosition: { x: 0, y: 123 } }
      pushReviewNavigationHash('#receipt-adjustment-1')
      popTo(0)
      process.stdout.write(JSON.stringify({ delegated: calls.length, scrolls, hash: window.location.hash }))
    JAVASCRIPT

    expect(result).to eq("delegated" => 0, "scrolls" => [ { "x" => 0, "y" => 123 } ], "hash" => "")
  end

  it "スクロール座標が不正な履歴では同じformを保ち先頭へ戻る" do
    result = run_module_script(browser_setup + <<~JAVASCRIPT)
      registerReviewNavigation(form)
      session.history.restorationData.initial = { scrollPosition: { x: 0, y: NaN } }
      pushReviewNavigationHash('#receipt-adjustment-1')
      popTo(0)
      process.stdout.write(JSON.stringify({ delegated: calls.length, scrolls }))
    JAVASCRIPT

    expect(result).to eq("delegated" => 0, "scrolls" => [ { "x" => 0, "y" => 0 } ])
  end

  it "初期位置が記録されていない履歴ではTurboの標準動作と同じく先頭へ戻る" do
    result = run_module_script(browser_setup + <<~JAVASCRIPT)
      registerReviewNavigation(form)
      pushReviewNavigationHash('#receipt-adjustment-1')
      popTo(0)
      process.stdout.write(JSON.stringify({ delegated: calls.length, scrolls }))
    JAVASCRIPT

    expect(result).to eq("delegated" => 0, "scrolls" => [ { "x" => 0, "y" => 0 } ])
  end

  it "空hashと現在のhashでは履歴を重ねない" do
    result = run_module_script(browser_setup + <<~JAVASCRIPT)
      registerReviewNavigation(form)
      pushReviewNavigationHash('#receipt-adjustment-1')
      const handled = [pushReviewNavigationHash(''), pushReviewNavigationHash('#'), pushReviewNavigationHash(window.location.hash)]
      process.stdout.write(JSON.stringify({ handled, pushes: pushes.length, hash: window.location.hash }))
    JAVASCRIPT

    expect(result).to eq("handled" => [ true, true, true ], "pushes" => 1, "hash" => "#receipt-adjustment-1")
  end

  {
    "別origin" => "window.history.replaceState(window.history.state, '', 'https://other.example/receipts/1/edit?tab=items')",
    "別レシート" => "window.history.replaceState(window.history.state, '', 'https://recify.example/receipts/2/edit?tab=items')",
    "別query" => "window.history.replaceState(window.history.state, '', 'https://recify.example/receipts/1/edit?tab=summary')",
    "別履歴group" => "window.history.state.recifyReviewNavigation.group = 'other-group'",
    "markerのない履歴" => "delete window.history.state.recifyReviewNavigation",
    "切断されたform" => "form.isConnected = false",
    "同じidで置換されたform" => "forms = [makeElement(form.id)]",
    "無効化されたsession" => "session.enabled = false"
  }.each do |condition, setup|
    it "#{condition}では元の履歴処理へthis・引数を渡し戻り値を保持する" do
      result = run_module_script(browser_setup + <<~JAVASCRIPT)
        registerReviewNavigation(form)
        #{setup}
        const location = window.location
        const extra = { opaque: true }
        const returned = session.historyPoppedToLocationWithRestorationIdentifierAndDirection(location, 'restore-id', 'back', extra)
        process.stdout.write(JSON.stringify({
          returned,
          delegated: calls.length,
          sameThis: calls[0].receiver === session,
          sameLocation: calls[0].args[0] === location,
          identifier: calls[0].args[1],
          direction: calls[0].args[2],
          sameExtra: calls[0].args[3] === extra,
          handled: pushReviewNavigationHash('#receipt-adjustment-2'),
          pushes: pushes.length
        }))
      JAVASCRIPT

      expect(result).to eq(
        "returned" => "delegated", "delegated" => 1, "sameThis" => true, "sameLocation" => true,
        "identifier" => "restore-id", "direction" => "back", "sameExtra" => true,
        "handled" => false, "pushes" => 0
      )
    end
  end

  {
    "取得処理中のhtml" => "html.attributes['aria-busy'] = 'true'",
    "送信処理中のform" => "form.attributes['aria-busy'] = 'true'",
    "別formの送信中" => "const otherForm = makeElement('other'); otherForm.attributes['aria-busy'] = 'true'; forms.push(otherForm)",
    "Turboのpreview" => "html.attributes['data-turbo-preview'] = ''"
  }.each do |condition, setup|
    it "#{condition}でも正規の履歴を登録し、復帰はTurboへ委譲する" do
      result = run_module_script(browser_setup + <<~JAVASCRIPT)
        registerReviewNavigation(form)
        pushReviewNavigationHash('#receipt-adjustment-1')
        #{setup}
        const handled = pushReviewNavigationHash('#receipt-adjustment-2')
        const pushedIdentifier = session.history.restorationIdentifier
        const pushedIndex = session.history.currentIndex
        const pushedHash = session.history.location.hash
        const returned = popTo(1)
        process.stdout.write(JSON.stringify({
          handled, pushedIdentifier, pushedIndex, pushedHash,
          returned, delegated: calls.length,
          restoredHash: session.history.location.hash
        }))
      JAVASCRIPT

      expect(result).to eq(
        "handled" => true, "pushedIdentifier" => "entry-2", "pushedIndex" => 2,
        "pushedHash" => "#receipt-adjustment-2", "returned" => "delegated", "delegated" => 1,
        "restoredHash" => "#receipt-adjustment-1"
      )
    end
  end

  it "必要なTurbo機能がない場合は元の履歴処理を変更しない" do
    result = run_module_script(browser_setup + <<~JAVASCRIPT)
      delete session.history.getRestorationDataForIdentifier
      const registration = registerReviewNavigation(form)
      const returned = session.historyPoppedToLocationWithRestorationIdentifierAndDirection(window.location, 'initial', 'back')
      process.stdout.write(JSON.stringify({
        registration,
        unchanged: original === session.historyPoppedToLocationWithRestorationIdentifierAndDirection,
        returned,
        marked: Object.hasOwn(window.history.state, 'recifyReviewNavigation'),
        handled: pushReviewNavigationHash('#receipt-adjustment-1')
      }))
    JAVASCRIPT

    expect(result).to eq("registration" => nil, "unchanged" => true, "returned" => "delegated", "marked" => false, "handled" => false)
  end

  it "同じsessionへ再登録してもwrapperを重ねず古いdisconnectで新登録を解除しない" do
    result = run_module_script(browser_setup + <<~JAVASCRIPT)
      const first = registerReviewNavigation(form)
      const handler = session.historyPoppedToLocationWithRestorationIdentifierAndDirection
      const second = registerReviewNavigation(form)
      unregisterReviewNavigation(first)
      const handled = pushReviewNavigationHash('#receipt-adjustment-1')
      popTo(0)
      const beforeUnregister = calls.length
      unregisterReviewNavigation(second)
      popTo(1)
      process.stdout.write(JSON.stringify({
        sameHandler: handler === session.historyPoppedToLocationWithRestorationIdentifierAndDirection,
        handled, beforeUnregister, afterUnregister: calls.length
      }))
    JAVASCRIPT

    expect(result).to eq("sameHandler" => true, "handled" => true, "beforeUnregister" => 0, "afterUnregister" => 1)
  end

  it "別ページから通常復帰したformは既存の履歴groupを引き継ぐ" do
    result = run_module_script(browser_setup + <<~JAVASCRIPT)
      const first = registerReviewNavigation(form)
      pushReviewNavigationHash('#receipt-adjustment-1')
      const previousGroup = window.history.state.recifyReviewNavigation.group
      unregisterReviewNavigation(first)
      form.isConnected = false
      window.history.pushState({ turbo: { restorationIdentifier: 'other', restorationIndex: 2 } }, '', 'https://recify.example/receipts')
      session.history.currentIndex = 2
      popTo(1)
      const restoredForm = makeElement(form.id)
      forms = [restoredForm]
      registerReviewNavigation(restoredForm)
      const adoptedGroup = window.history.state.recifyReviewNavigation.group
      pushReviewNavigationHash('#receipt-adjustment-2')
      popTo(1)
      process.stdout.write(JSON.stringify({ sameGroup: adoptedGroup === previousGroup, delegated: calls.length, pushes: pushes.length }))
    JAVASCRIPT

    expect(result).to eq("sameGroup" => true, "delegated" => 1, "pushes" => 2)
  end

  it "windowがない環境でも読み込めて未登録の解除を安全に扱う" do
    result = run_module_script(<<~JAVASCRIPT)
      unregisterReviewNavigation(null)
      unregisterReviewNavigation(undefined)
      process.stdout.write(JSON.stringify({ registration: registerReviewNavigation(null), handled: pushReviewNavigationHash('#receipt-adjustment-1') }))
    JAVASCRIPT

    expect(result).to eq("registration" => nil, "handled" => false)
  end
end
