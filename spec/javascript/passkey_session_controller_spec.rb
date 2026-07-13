# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Passkey session Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/passkey_session_controller.js").read }

  def run_controller_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class PasskeySessionController extends Controller')

      eval(`${source}\nglobalThis.PasskeySessionController = PasskeySessionController`)
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

  it "preload失敗後のclickでoptionsを再取得してloginできる" do
    result = run_controller_script(<<~JAVASCRIPT)
      const requestUrls = []
      const redirects = []
      let optionsCalls = 0
      let credentialGetCalls = 0

      const response = (ok, payload) => ({
        ok,
        json: async () => payload
      })
      const publicKey = {
        challenge: 'AQ',
        allowCredentials: [{ type: 'public-key', id: 'Ag' }]
      }
      const bytes = (value) => new Uint8Array([value]).buffer
      const credential = {
        type: 'public-key',
        id: 'credential-id',
        rawId: bytes(1),
        authenticatorAttachment: null,
        getClientExtensionResults: () => ({}),
        response: {
          authenticatorData: bytes(2),
          clientDataJSON: bytes(3),
          signature: bytes(4),
          userHandle: null
        }
      }

      globalThis.document = { querySelector: () => ({ content: 'csrf-token' }) }
      Object.defineProperty(globalThis, 'navigator', {
        configurable: true,
        value: {
          credentials: {
            get: async () => {
              credentialGetCalls += 1
              return credential
            }
          }
        }
      })
      globalThis.window = {
        PublicKeyCredential: class {},
        atob: globalThis.atob,
        btoa: globalThis.btoa,
        location: { assign: (url) => redirects.push(url) }
      }
      globalThis.fetch = async (url) => {
        requestUrls.push(url)

        if (url === '/passkey/options') {
          optionsCalls += 1
          if (optionsCalls === 1) return response(false, { error: 'temporary preload failure' })

          return response(true, { publicKey })
        }

        return response(true, { redirect_url: '/after-login' })
      }

      const hiddenClasses = new Set(['hidden'])
      const buttonClasses = new Set()
      const controller = Object.create(PasskeySessionController.prototype)
      controller.optionsUrlValue = '/passkey/options'
      controller.createUrlValue = '/passkey/session'
      controller.requestFailedMessageValue = 'request failed'
      controller.failureMessageValue = 'login failed'
      controller.unsupportedMessageValue = 'unsupported'
      controller.conditionalValue = false
      controller.hasButtonTarget = true
      controller.buttonTarget = {
        disabled: false,
        classList: {
          toggle: (name, enabled) => enabled ? buttonClasses.add(name) : buttonClasses.delete(name)
        }
      }
      controller.hasErrorTarget = true
      controller.errorTarget = {
        textContent: '',
        classList: {
          add: (name) => hiddenClasses.add(name),
          remove: (name) => hiddenClasses.delete(name)
        }
      }

      controller.connect()
      await new Promise((resolve) => setTimeout(resolve, 0))
      await controller.login({ preventDefault: () => {} })

      process.stdout.write(JSON.stringify({
        requestUrls,
        redirects,
        credentialGetCalls,
        errorText: controller.errorTarget.textContent,
        errorHidden: hiddenClasses.has('hidden'),
        buttonDisabled: controller.buttonTarget.disabled,
        buttonLoading: buttonClasses.has('opacity-60')
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["requestUrls"]).to eq([ "/passkey/options", "/passkey/options", "/passkey/session" ])
      expect(result["redirects"]).to eq([ "/after-login" ])
      expect(result["credentialGetCalls"]).to eq(1)
      expect(result["errorText"]).to eq("")
      expect(result["errorHidden"]).to be(true)
      expect(result["buttonDisabled"]).to be(true)
      expect(result["buttonLoading"]).to be(true)
    end
  end

  it "create成功後はnavigationと競合するoptions再取得を行わない" do
    result = run_controller_script(<<~JAVASCRIPT)
      const requestUrls = []
      const requestsAfterRedirect = []
      const redirects = []
      let redirected = false
      let credentialGetCalls = 0

      const response = (payload) => ({ ok: true, json: async () => payload })
      const publicKey = { challenge: 'AQ', allowCredentials: [] }
      const bytes = (value) => new Uint8Array([value]).buffer
      const credential = {
        type: 'public-key',
        id: 'credential-id',
        rawId: bytes(1),
        authenticatorAttachment: null,
        getClientExtensionResults: () => ({}),
        response: {
          authenticatorData: bytes(2),
          clientDataJSON: bytes(3),
          signature: bytes(4),
          userHandle: null
        }
      }

      globalThis.document = { querySelector: () => ({ content: 'csrf-token' }) }
      Object.defineProperty(globalThis, 'navigator', {
        configurable: true,
        value: {
          credentials: {
            get: async () => {
              credentialGetCalls += 1
              return credential
            }
          }
        }
      })
      globalThis.window = {
        PublicKeyCredential: class {},
        atob: globalThis.atob,
        btoa: globalThis.btoa,
        location: {
          assign: (url) => {
            redirected = true
            redirects.push(url)
          }
        }
      }
      globalThis.fetch = async (url) => {
        requestUrls.push(url)
        if (redirected) requestsAfterRedirect.push(url)

        if (url === '/passkey/options') return response({ publicKey })

        return response({ redirect_url: '/after-login' })
      }

      const controller = Object.create(PasskeySessionController.prototype)
      controller.optionsUrlValue = '/passkey/options'
      controller.createUrlValue = '/passkey/session'
      controller.requestFailedMessageValue = 'request failed'
      controller.failureMessageValue = 'login failed'
      controller.unsupportedMessageValue = 'unsupported'
      controller.conditionalValue = false
      controller.hasButtonTarget = true
      controller.buttonTarget = {
        disabled: false,
        classList: { toggle: () => {} }
      }
      controller.hasErrorTarget = true
      controller.errorTarget = {
        textContent: '',
        classList: { add: () => {}, remove: () => {} }
      }

      controller.connect()
      await new Promise((resolve) => setTimeout(resolve, 0))
      await controller.login({ preventDefault: () => {} })

      process.stdout.write(JSON.stringify({
        requestUrls,
        requestsAfterRedirect,
        redirects,
        credentialGetCalls,
        buttonDisabled: controller.buttonTarget.disabled
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["requestUrls"]).to eq([ "/passkey/options", "/passkey/session" ])
      expect(result["requestsAfterRedirect"]).to be_empty
      expect(result["redirects"]).to eq([ "/after-login" ])
      expect(result["credentialGetCalls"]).to eq(1)
      expect(result["buttonDisabled"]).to be(true)
    end
  end

  it "create失敗時はbuttonを再有効化し、準備し直したoptionsで再試行できる" do
    result = run_controller_script(<<~JAVASCRIPT)
      const requestUrls = []
      const redirects = []
      let sessionCalls = 0
      let credentialGetCalls = 0

      const response = (ok, payload) => ({
        ok,
        json: async () => payload
      })
      const publicKey = { challenge: 'AQ', allowCredentials: [] }
      const bytes = (value) => new Uint8Array([value]).buffer
      const credential = {
        type: 'public-key',
        id: 'credential-id',
        rawId: bytes(1),
        authenticatorAttachment: null,
        getClientExtensionResults: () => ({}),
        response: {
          authenticatorData: bytes(2),
          clientDataJSON: bytes(3),
          signature: bytes(4),
          userHandle: null
        }
      }

      globalThis.document = { querySelector: () => ({ content: 'csrf-token' }) }
      Object.defineProperty(globalThis, 'navigator', {
        configurable: true,
        value: {
          credentials: {
            get: async () => {
              credentialGetCalls += 1
              return credential
            }
          }
        }
      })
      globalThis.window = {
        PublicKeyCredential: class {},
        atob: globalThis.atob,
        btoa: globalThis.btoa,
        location: { assign: (url) => redirects.push(url) }
      }
      globalThis.fetch = async (url) => {
        requestUrls.push(url)
        if (url === '/passkey/options') return response(true, { publicKey })

        sessionCalls += 1
        if (sessionCalls === 1) return response(false, { error: 'temporary create failure' })

        return response(true, { redirect_url: '/after-login' })
      }

      const hiddenClasses = new Set(['hidden'])
      const buttonClasses = new Set()
      const controller = Object.create(PasskeySessionController.prototype)
      controller.optionsUrlValue = '/passkey/options'
      controller.createUrlValue = '/passkey/session'
      controller.requestFailedMessageValue = 'request failed'
      controller.failureMessageValue = 'login failed'
      controller.unsupportedMessageValue = 'unsupported'
      controller.conditionalValue = false
      controller.hasButtonTarget = true
      controller.buttonTarget = {
        disabled: false,
        classList: {
          toggle: (name, enabled) => enabled ? buttonClasses.add(name) : buttonClasses.delete(name)
        }
      }
      controller.hasErrorTarget = true
      controller.errorTarget = {
        textContent: '',
        classList: {
          add: (name) => hiddenClasses.add(name),
          remove: (name) => hiddenClasses.delete(name)
        }
      }

      controller.connect()
      await new Promise((resolve) => setTimeout(resolve, 0))
      await controller.login({ preventDefault: () => {} })
      await new Promise((resolve) => setTimeout(resolve, 0))
      const afterFailure = {
        disabled: controller.buttonTarget.disabled,
        loading: buttonClasses.has('opacity-60'),
        errorText: controller.errorTarget.textContent,
        errorHidden: hiddenClasses.has('hidden')
      }

      await controller.login({ preventDefault: () => {} })

      process.stdout.write(JSON.stringify({
        requestUrls,
        redirects,
        credentialGetCalls,
        afterFailure,
        finalDisabled: controller.buttonTarget.disabled,
        finalLoading: buttonClasses.has('opacity-60')
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["requestUrls"]).to eq([
        "/passkey/options",
        "/passkey/session",
        "/passkey/options",
        "/passkey/session"
      ])
      expect(result["redirects"]).to eq([ "/after-login" ])
      expect(result["credentialGetCalls"]).to eq(2)
      expect(result["afterFailure"]).to eq(
        "disabled" => false,
        "loading" => false,
        "errorText" => "temporary create failure",
        "errorHidden" => false
      )
      expect(result["finalDisabled"]).to be(true)
      expect(result["finalLoading"]).to be(true)
    end
  end
end
