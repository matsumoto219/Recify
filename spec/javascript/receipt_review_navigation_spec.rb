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
    source = File.read(File.expand_path("../../app/javascript/receipts/review_navigation.js", __dir__)).gsub(/^export /, "")
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
      eval(`${source}\n#{script}`)
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
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
