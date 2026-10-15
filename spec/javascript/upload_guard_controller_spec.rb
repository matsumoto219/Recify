# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "spec_helper"

RSpec.describe "Upload guard Stimulus controller" do
  let(:source) { File.read(File.expand_path("../../app/javascript/controllers/upload_guard_controller.js", __dir__)) }

  def run_controller_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace("import { Turbo } from '@hotwired/turbo-rails'", 'const Turbo = globalThis.Turbo')
        .replace('export default class extends Controller', 'class UploadGuardController extends Controller')
      const visits = [], confirmations = [], discards = []
      globalThis.Turbo = { visit: (url) => visits.push(url) }
      globalThis.window = new EventTarget()
      globalThis.document = new EventTarget()
      window.location = new URL('https://example.test/receipts/new_upload')
      document.activeElement = { name: 'cancel-link' }
      let answer = false
      window.RecifyConfirm = {
        confirm (message, options) {
          confirmations.push({ message, ...options })
          return Promise.resolve(answer)
        }
      }
      eval(`${source}\nglobalThis.UploadGuardController = UploadGuardController`)

      const input = { type: 'file', disabled: false, files: [] }
      Object.defineProperty(input, 'value', { set (value) { if (value === '') this.files = [] } })
      const form = new EventTarget()
      form.elements = [input, { type: 'text', value: 'unsaved text' }]
      form.isConnected = true
      form.addEventListener('upload-guard:discard', (event) => discards.push({ files: input.files.length, bubbles: event.bubbles }))
      const controller = Object.create(UploadGuardController.prototype)
      Object.assign(controller, {
        element: form,
        titleValue: '画像を保存せずに移動しますか？',
        messageValue: '画像は保存されません。',
        pendingMessageValue: '送信結果を確認できていません。',
        leaveLabelValue: 'このページを離れる',
        stayLabelValue: 'このページに戻る'
      })
      controller.connect()
      function send (target, type, detail = {}) {
        const event = new Event(type, { cancelable: true })
        event.detail = detail
        target.dispatchEvent(event)
        return event.defaultPrevented
      }
      function visit (url = 'https://example.test/receipts') {
        return send(document, 'turbo:before-visit', { url })
      }
      const flush = () => new Promise((resolve) => setImmediate(resolve))
      ;(async () => {
        #{script}
      })().catch((error) => { process.stderr.write(error.stack); process.exitCode = 1 })
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "does not warn for persisted images, text changes, or image-free submission" do
    result = run_controller_script(<<~JAVASCRIPT)
      send(form, 'turbo:submit-start')
      const unload = send(window, 'beforeunload')
      const navigation = visit()
      await flush()
      process.stdout.write(JSON.stringify({ unload, navigation, confirmations }))
    JAVASCRIPT

    expect(result).to eq("unload" => false, "navigation" => false, "confirmations" => [])
  end

  it "guards selected files including programmatic camera or drop selection and stops after clearing" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      const selected = send(window, 'beforeunload')
      input.files = []
      const cleared = send(window, 'beforeunload')
      process.stdout.write(JSON.stringify({ selected, cleared }))
    JAVASCRIPT

    expect(result).to eq("selected" => true, "cleared" => false)
  end

  it "sets a nonempty beforeunload return value for native confirmation compatibility" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      const event = { preventDefault () { this.prevented = true }, returnValue: '' }
      controller.handleBeforeUnload(event)
      process.stdout.write(JSON.stringify({ prevented: event.prevented, returnValue: event.returnValue }))
    JAVASCRIPT

    expect(result).to eq("prevented" => true, "returnValue" => true)
  end

  it "uses the shared dialog and stays on the form when cancelled" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      const prevented = visit()
      await flush()
      process.stdout.write(JSON.stringify({ prevented, confirmations, visits, discards, files: input.files.length, unload: send(window, 'beforeunload') }))
    JAVASCRIPT

    expect(result).to include("prevented" => true, "visits" => [], "discards" => [], "files" => 1, "unload" => true)
    expect(result.fetch("confirmations")).to eq([
      {
        "message" => "画像は保存されません。", "title" => "画像を保存せずに移動しますか？",
        "confirmLabel" => "このページを離れる", "cancelLabel" => "このページに戻る",
        "icon" => "warning", "restoreFocusElement" => { "name" => "cancel-link" }
      }
    ])
  end

  it "discards only browser selection on confirmed departure before navigating" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      answer = true
      visit()
      await flush()
      const confirmed = visit()
      const unload = send(window, 'beforeunload')
      const later = visit('https://example.test/settings')
      await flush()
      process.stdout.write(JSON.stringify({ visits, confirmed, unload, later, count: confirmations.length, discards, files: input.files.length, text: form.elements[1].value }))
    JAVASCRIPT

    expect(result).to eq(
      "visits" => [ "https://example.test/receipts" ],
      "confirmed" => false, "unload" => false, "later" => false, "count" => 1,
      "discards" => [ { "files" => 0, "bubbles" => true } ], "files" => 0, "text" => "unsaved text"
    )
  end

  it "allows an in-flight departure once without treating browser cleanup as server cancellation" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(form, 'turbo:submit-start')
      answer = true
      visit()
      await flush()
      const confirmed = visit()
      const unload = send(window, 'beforeunload')
      answer = false
      const later = visit('https://example.test/settings')
      await flush()
      process.stdout.write(JSON.stringify({ visits, confirmed, unload, later, count: confirmations.length, discards }))
    JAVASCRIPT

    expect(result).to eq(
      "visits" => [ "https://example.test/receipts" ],
      "confirmed" => false, "unload" => true, "later" => true, "count" => 2,
      "discards" => [ { "files" => 0, "bubbles" => true } ]
    )
  end

  it "coalesces repeated navigation into one dialog" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      let resolve
      window.RecifyConfirm.confirm = () => { confirmations.push({}); return new Promise((done) => { resolve = done }) }
      const first = visit(), second = visit('https://example.test/settings')
      resolve(false)
      await flush()
      process.stdout.write(JSON.stringify({ first, second, count: confirmations.length, visits }))
    JAVASCRIPT

    expect(result).to eq("first" => true, "second" => true, "count" => 1, "visits" => [])
  end

  it "keeps in-flight protection after the selected input is cleared and does nothing on tab hiding" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(form, 'turbo:submit-start')
      input.files = []
      document.hidden = true
      send(document, 'visibilitychange')
      const unload = send(window, 'beforeunload')
      visit()
      await flush()
      process.stdout.write(JSON.stringify({ unload, message: confirmations[0].message, visits, discards }))
    JAVASCRIPT

    expect(result).to eq("unload" => true, "message" => "送信結果を確認できていません。", "visits" => [], "discards" => [])
  end

  it "keeps selected-file protection on network failure and validation errors without claiming cancellation" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(form, 'turbo:submit-start')
      send(form, 'turbo:submit-end', { success: false, error: new Error('offline') })
      const offline = send(window, 'beforeunload')
      send(form, 'turbo:submit-start')
      send(form, 'turbo:submit-end', { success: false, fetchResponse: { statusCode: 422 } })
      const invalid = send(window, 'beforeunload')
      process.stdout.write(JSON.stringify({ offline, invalid }))
    JAVASCRIPT

    expect(result).to eq("offline" => true, "invalid" => true)
  end

  it "does not treat a successful HTTP redirect as confirmed domain acceptance" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(form, 'turbo:submit-start')
      send(form, 'turbo:submit-end', { success: true, fetchResponse: { redirected: true } })
      process.stdout.write(JSON.stringify({ unload: send(window, 'beforeunload'), navigation: visit() }))
    JAVASCRIPT

    expect(result).to eq("unload" => true, "navigation" => true)
  end

  it "allows only the form's own response navigation once without clearing its file protection" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(form, 'turbo:submit-start')
      const url = 'https://example.test/receipts/accepted'
      send(form, 'turbo:before-fetch-response', { fetchResponse: { location: new URL(url) } })
      const resultNavigation = visit(url)
      const unload = send(window, 'beforeunload')
      const unrelated = visit('https://example.test/settings')
      await flush()
      process.stdout.write(JSON.stringify({ resultNavigation, unload, unrelated, count: confirmations.length, discards }))
    JAVASCRIPT

    expect(result).to eq("resultNavigation" => false, "unload" => true, "unrelated" => true, "count" => 1, "discards" => [])
  end

  it "does not retain a response navigation exemption after a failed submission" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(form, 'turbo:submit-start')
      const url = 'https://example.test/receipts/accepted'
      send(form, 'turbo:before-fetch-response', { fetchResponse: { location: new URL(url) } })
      send(form, 'turbo:submit-end', { success: false, error: new Error('offline') })
      const prevented = visit(url)
      await flush()
      process.stdout.write(JSON.stringify({ prevented, files: input.files.length, discards, count: confirmations.length }))
    JAVASCRIPT

    expect(result).to eq("prevented" => true, "files" => 1, "discards" => [], "count" => 1)
  end

  it "does not reuse a prior response navigation exemption for a new submission" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(form, 'turbo:submit-start')
      const url = 'https://example.test/receipts/accepted'
      send(form, 'turbo:before-fetch-response', { fetchResponse: { location: new URL(url) } })
      send(form, 'turbo:submit-end', { success: true })
      send(form, 'turbo:submit-start')
      const prevented = visit(url)
      await flush()
      process.stdout.write(JSON.stringify({ prevented, count: confirmations.length }))
    JAVASCRIPT

    expect(result).to eq("prevented" => true, "count" => 1)
  end

  it "invalidates an unused response exemption when another navigation is attempted" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(form, 'turbo:submit-start')
      const url = 'https://example.test/receipts/accepted'
      send(form, 'turbo:before-fetch-response', { fetchResponse: { location: new URL(url) } })
      visit('https://example.test/settings')
      await flush()
      const prevented = visit(url)
      await flush()
      process.stdout.write(JSON.stringify({ prevented, count: confirmations.length }))
    JAVASCRIPT

    expect(result).to eq("prevented" => true, "count" => 2)
  end

  it "ignores an unrelated form response and same-page anchor navigation" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(document, 'turbo:before-fetch-response', { fetchResponse: { location: new URL('https://example.test/receipts') } })
      const anchor = visit('https://example.test/receipts/new_upload#preview')
      window.location.hash = '#preview'
      const removeAnchor = visit('https://example.test/receipts/new_upload')
      const other = visit()
      await flush()
      process.stdout.write(JSON.stringify({ anchor, removeAnchor, other, count: confirmations.length }))
    JAVASCRIPT

    expect(result).to eq("anchor" => false, "removeAnchor" => false, "other" => true, "count" => 1)
  end

  it "does not resume a pending dialog after the owning form disconnects" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      let resolve
      window.RecifyConfirm.confirm = () => new Promise((done) => { resolve = done })
      visit()
      controller.disconnect()
      resolve(true)
      await flush()
      process.stdout.write(JSON.stringify({ visits, unload: send(window, 'beforeunload') }))
    JAVASCRIPT

    expect(result).to eq("visits" => [], "unload" => false)
  end

  it "preserves live input protection during cache preparation but does not restore stale submitting state" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(form, 'turbo:submit-start')
      send(document, 'turbo:before-cache')
      const live = send(window, 'beforeunload')
      controller.disconnect()
      input.files = []
      controller.connect()
      const restored = send(window, 'beforeunload')
      process.stdout.write(JSON.stringify({ live, restored }))
    JAVASCRIPT

    expect(result).to eq("live" => true, "restored" => false)
  end

  it "fails closed without the shared dialog and leaves file selection untouched" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      delete window.RecifyConfirm
      const prevented = visit()
      await flush()
      process.stdout.write(JSON.stringify({ prevented, visits, files: input.files.length }))
    JAVASCRIPT

    expect(result).to eq("prevented" => true, "visits" => [], "files" => 1)
  end

  it "does not leak a rejected dialog promise or navigate when confirmation is unavailable" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      window.RecifyConfirm.confirm = () => Promise.reject(new Error('dialog unavailable'))
      const prevented = visit()
      await flush()
      process.stdout.write(JSON.stringify({ prevented, visits, unload: send(window, 'beforeunload') }))
    JAVASCRIPT

    expect(result).to eq("prevented" => true, "visits" => [], "unload" => true)
  end

  it "rechecks browser-restored files without reviving an interrupted submission" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(form, 'turbo:submit-start')
      const restored = new Event('pageshow')
      restored.persisted = true
      window.dispatchEvent(restored)
      const selected = send(window, 'beforeunload')
      input.files = []
      const empty = send(window, 'beforeunload')
      process.stdout.write(JSON.stringify({ selected, empty }))
    JAVASCRIPT

    expect(result).to eq("selected" => true, "empty" => false)
  end

  it "discards browser references only after native departure and does not restore them from bfcache" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(form, 'turbo:submit-start')
      const prompted = send(window, 'beforeunload')
      const beforeDeparture = { files: input.files.length, discards: discards.length }
      send(window, 'pagehide')
      const restored = new Event('pageshow')
      restored.persisted = true
      window.dispatchEvent(restored)
      process.stdout.write(JSON.stringify({ prompted, beforeDeparture, files: input.files.length, discards, unload: send(window, 'beforeunload') }))
    JAVASCRIPT

    expect(result).to eq(
      "prompted" => true, "beforeDeparture" => { "files" => 1, "discards" => 0 },
      "files" => 0, "discards" => [ { "files" => 0, "bubbles" => true } ], "unload" => false
    )
  end

  it "discards a selected image when a cross-page history restore prepares the outgoing page for cache" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      window.location = new URL('https://example.test/receipts#recent')
      send(document, 'turbo:visit', { url: window.location.href, action: 'restore' })
      send(document, 'turbo:before-cache')
      send(document, 'turbo:before-cache')
      controller.disconnect()
      window.location = new URL('https://example.test/receipts/new_upload')
      controller.connect()
      process.stdout.write(JSON.stringify({ files: input.files.length, discards, unload: send(window, 'beforeunload') }))
    JAVASCRIPT

    expect(result).to eq("files" => 0, "discards" => [ { "files" => 0, "bubbles" => true } ], "unload" => false)
  end

  it "keeps in-flight protection when navigation cache cleanup releases browser references" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(form, 'turbo:submit-start')
      send(document, 'turbo:visit', { url: 'https://example.test/receipts', action: 'advance' })
      send(document, 'turbo:before-cache')
      const beforeResult = send(window, 'beforeunload')
      send(form, 'turbo:submit-end', { success: true })
      process.stdout.write(JSON.stringify({ files: input.files.length, beforeResult, afterResult: send(window, 'beforeunload') }))
    JAVASCRIPT

    expect(result).to eq("files" => 0, "beforeResult" => true, "afterResult" => false)
  end

  it "keeps selected images for same-page hash history and replaces any stale cross-page marker" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(document, 'turbo:visit', { url: 'https://example.test/receipts', action: 'restore' })
      window.location.hash = '#preview'
      send(document, 'turbo:visit', { url: window.location.href, action: 'restore' })
      send(document, 'turbo:before-cache')
      window.location.hash = ''
      send(document, 'turbo:visit', { url: window.location.href, action: 'restore' })
      send(document, 'turbo:before-cache')
      process.stdout.write(JSON.stringify({ files: input.files.length, discards }))
    JAVASCRIPT

    expect(result).to eq("files" => 1, "discards" => [])
  end

  it "does not apply a failed navigation's cache cleanup to a later cache operation" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(document, 'turbo:visit', { url: 'https://example.test/receipts', action: 'advance' })
      send(document, 'turbo:fetch-request-error', { error: new Error('offline') })
      send(document, 'turbo:before-cache')
      process.stdout.write(JSON.stringify({ files: input.files.length, discards }))
    JAVASCRIPT

    expect(result).to eq("files" => 1, "discards" => [])
  end

  it "clears unused navigation cleanup after load and a persisted page restoration" do
    result = run_controller_script(<<~JAVASCRIPT)
      input.files = [{}]
      send(document, 'turbo:visit', { url: 'https://example.test/receipts', action: 'advance' })
      send(document, 'turbo:load')
      send(document, 'turbo:before-cache')
      const afterLoad = input.files.length
      send(document, 'turbo:visit', { url: 'https://example.test/receipts', action: 'advance' })
      const restored = new Event('pageshow')
      restored.persisted = true
      window.dispatchEvent(restored)
      send(document, 'turbo:before-cache')
      process.stdout.write(JSON.stringify({ afterLoad, files: input.files.length, discards }))
    JAVASCRIPT

    expect(result).to eq("afterLoad" => 1, "files" => 1, "discards" => [])
  end
end
