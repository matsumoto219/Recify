# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "spec_helper"

RSpec.describe "Receipt registration transport feedback" do
  let(:source) { File.read(File.expand_path("../../app/javascript/controllers/receipt_registration_controller.js", __dir__)) }

  def run_controller_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class ReceiptRegistrationController extends Controller')
      globalThis.window = new EventTarget()
      globalThis.document = new EventTarget()
      Object.defineProperty(window, 'localStorage', { get () { throw Error('persistent storage is not part of registration') } })
      Object.defineProperty(globalThis, 'navigator', { value: {}, configurable: true })
      globalThis.fetch = () => { throw Error('automatic request is not allowed') }
      eval(`${source}\nglobalThis.ReceiptRegistrationController = ReceiptRegistrationController`)
      const form = new EventTarget()
      const token = { value: 'same-form-token' }
      form.elements = [token]
      const error = { hidden: true, textContent: '通信が途切れ、登録結果を確認できませんでした。' }
      const controller = Object.create(ReceiptRegistrationController.prototype)
      Object.assign(controller, { element: form, errorTarget: error })
      controller.connect()
      function send (target, type, detail = {}) {
        const event = new Event(type, { cancelable: true })
        event.detail = detail
        target.dispatchEvent(event)
      }
      #{script}
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "reports a transport error without changing the token or sending recovery requests" do
    result = run_controller_script(<<~JAVASCRIPT)
      send(form, 'turbo:fetch-request-error', { error: new Error('private network detail') })
      send(form, 'turbo:submit-end', { success: false })
      process.stdout.write(JSON.stringify({ hidden: error.hidden, message: error.textContent, token: token.value }))
    JAVASCRIPT

    expect(result).to eq(
      "hidden" => false, "message" => "通信が途切れ、登録結果を確認できませんでした。", "token" => "same-form-token"
    )
  end

  it "leaves ordinary server validation responses to the existing form errors" do
    result = run_controller_script(<<~JAVASCRIPT)
      send(form, 'turbo:submit-end', { success: false, fetchResponse: { statusCode: 422 } })
      process.stdout.write(JSON.stringify({ hidden: error.hidden, token: token.value }))
    JAVASCRIPT

    expect(result).to eq("hidden" => true, "token" => "same-form-token")
  end

  it "clears stale feedback on explicit retry and before Turbo cache without regenerating identity" do
    result = run_controller_script(<<~JAVASCRIPT)
      send(form, 'turbo:fetch-request-error')
      send(form, 'turbo:submit-start')
      const retryHidden = error.hidden
      send(form, 'turbo:fetch-request-error')
      send(document, 'turbo:before-cache')
      process.stdout.write(JSON.stringify({ retryHidden, cachedHidden: error.hidden, token: token.value }))
    JAVASCRIPT

    expect(result).to eq("retryHidden" => true, "cachedHidden" => true, "token" => "same-form-token")
  end

  it "does not react to another form or retain listeners after disconnect" do
    result = run_controller_script(<<~JAVASCRIPT)
      send(document, 'turbo:fetch-request-error')
      const unrelatedHidden = error.hidden
      controller.disconnect()
      send(form, 'turbo:fetch-request-error')
      process.stdout.write(JSON.stringify({ unrelatedHidden, disconnectedHidden: error.hidden }))
    JAVASCRIPT

    expect(result).to eq("unrelatedHidden" => true, "disconnectedHidden" => true)
  end
end
