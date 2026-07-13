# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Passkey registration Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/passkey_controller.js").read }

  def run_controller_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class PasskeyController extends Controller')

      eval(`${source}\nglobalThis.PasskeyController = PasskeyController`)
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

  def registration_credential_source
    <<~JAVASCRIPT
      const bytes = (value) => new Uint8Array([value]).buffer
      const credential = {
        type: 'public-key',
        id: 'credential-id',
        rawId: bytes(1),
        authenticatorAttachment: null,
        getClientExtensionResults: () => ({}),
        response: {
          attestationObject: bytes(2),
          clientDataJSON: bytes(3),
          getTransports: () => ['internal']
        }
      }
    JAVASCRIPT
  end

  def registration_controller_source
    <<~JAVASCRIPT
      const hiddenErrorClasses = new Set(['hidden'])
      const hiddenSuccessClasses = new Set(['hidden'])
      const buttonClasses = new Set()
      const controller = Object.create(PasskeyController.prototype)
      controller.optionsUrlValue = '/passkey/options'
      controller.createUrlValue = '/passkey'
      controller.requestFailedMessageValue = 'request failed'
      controller.failureMessageValue = 'registration failed'
      controller.successMessageValue = 'registered'
      controller.unsupportedMessageValue = 'unsupported'
      controller.hasButtonTarget = true
      controller.buttonTarget = {
        disabled: false,
        classList: {
          toggle: (name, enabled) => enabled ? buttonClasses.add(name) : buttonClasses.delete(name)
        }
      }
      controller.hasLabelTarget = true
      controller.labelTarget = { value: 'Laptop' }
      controller.hasErrorTarget = true
      controller.errorTarget = {
        textContent: '',
        classList: {
          add: (name) => hiddenErrorClasses.add(name),
          remove: (name) => hiddenErrorClasses.delete(name)
        }
      }
      controller.hasSuccessTarget = true
      controller.successTarget = {
        textContent: '',
        classList: {
          add: (name) => hiddenSuccessClasses.add(name),
          remove: (name) => hiddenSuccessClasses.delete(name)
        }
      }
    JAVASCRIPT
  end

  it "preloadの428では遷移せず、登録操作時だけ再認証へ遷移する" do
    result = run_controller_script(<<~JAVASCRIPT)
      const redirects = []
      let credentialCreateCalls = 0
      let fetchCalls = 0
      globalThis.document = { querySelector: () => ({ content: 'csrf-token' }) }
      Object.defineProperty(globalThis, 'navigator', {
        configurable: true,
        value: {
          credentials: {
            create: async () => {
              credentialCreateCalls += 1
              return null
            }
          }
        }
      })
      globalThis.window = {
        PublicKeyCredential: class {},
        location: { assign: (url) => redirects.push(url) }
      }
      globalThis.fetch = async () => {
        fetchCalls += 1
        return {
          ok: false,
          status: 428,
          json: async () => ({
            error: 'reauthentication required',
            reauthentication_url: '/settings/security/reauthentication/new'
          })
        }
      }

      #{registration_controller_source}
      controller.optionsUrlValue = '/settings/passkeys/options'
      controller.createUrlValue = '/settings/passkeys'
      controller.connect()
      await new Promise((resolve) => setTimeout(resolve, 0))
      const redirectsAfterPreload = [...redirects]

      await controller.register({ preventDefault: () => {} })

      process.stdout.write(JSON.stringify({
        redirectsAfterPreload,
        redirects,
        fetchCalls,
        credentialCreateCalls,
        buttonDisabled: controller.buttonTarget.disabled,
        buttonLoading: buttonClasses.has('opacity-60')
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["redirectsAfterPreload"]).to be_empty
      expect(result["redirects"]).to eq([ "/settings/security/reauthentication/new" ])
      expect(result["fetchCalls"]).to eq(1)
      expect(result["credentialCreateCalls"]).to eq(0)
      expect(result["buttonDisabled"]).to be(true)
      expect(result["buttonLoading"]).to be(true)
    end
  end

  it "preload失敗後のclickでoptionsを再取得して登録できる" do
    result = run_controller_script(<<~JAVASCRIPT)
      const requestUrls = []
      let optionsCalls = 0
      let credentialCreateCalls = 0
      let reloadCalls = 0
      const response = (ok, payload) => ({ ok, json: async () => payload })
      const publicKey = {
        challenge: 'AQ',
        user: { id: 'Ag' },
        excludeCredentials: []
      }
      #{registration_credential_source}

      globalThis.document = { querySelector: () => ({ content: 'csrf-token' }) }
      Object.defineProperty(globalThis, 'navigator', {
        configurable: true,
        value: {
          credentials: {
            create: async () => {
              credentialCreateCalls += 1
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
          assign: () => {},
          reload: () => { reloadCalls += 1 }
        }
      }
      globalThis.fetch = async (url) => {
        requestUrls.push(url)
        if (url === '/passkey/options') {
          optionsCalls += 1
          if (optionsCalls === 1) return response(false, { error: 'temporary preload failure' })

          return response(true, { publicKey })
        }

        return response(true, { ok: true })
      }

      #{registration_controller_source}
      controller.connect()
      await new Promise((resolve) => setTimeout(resolve, 0))
      await controller.register({ preventDefault: () => {} })

      process.stdout.write(JSON.stringify({
        requestUrls,
        credentialCreateCalls,
        reloadCalls,
        errorText: controller.errorTarget.textContent,
        errorHidden: hiddenErrorClasses.has('hidden'),
        buttonDisabled: controller.buttonTarget.disabled,
        buttonLoading: buttonClasses.has('opacity-60')
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["requestUrls"]).to eq([ "/passkey/options", "/passkey/options", "/passkey" ])
      expect(result["credentialCreateCalls"]).to eq(1)
      expect(result["reloadCalls"]).to eq(1)
      expect(result["errorText"]).to eq("")
      expect(result["errorHidden"]).to be(true)
      expect(result["buttonDisabled"]).to be(true)
      expect(result["buttonLoading"]).to be(true)
    end
  end

  it "登録成功後はnavigationと競合するoptions再取得を行わない" do
    result = run_controller_script(<<~JAVASCRIPT)
      const requestUrls = []
      const requestsAfterReload = []
      let reloading = false
      let credentialCreateCalls = 0
      let reloadCalls = 0
      const response = (payload) => ({ ok: true, json: async () => payload })
      const publicKey = {
        challenge: 'AQ',
        user: { id: 'Ag' },
        excludeCredentials: []
      }
      #{registration_credential_source}

      globalThis.document = { querySelector: () => ({ content: 'csrf-token' }) }
      Object.defineProperty(globalThis, 'navigator', {
        configurable: true,
        value: {
          credentials: {
            create: async () => {
              credentialCreateCalls += 1
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
          assign: () => {},
          reload: () => {
            reloading = true
            reloadCalls += 1
          }
        }
      }
      globalThis.fetch = async (url) => {
        requestUrls.push(url)
        if (reloading) requestsAfterReload.push(url)
        if (url === '/passkey/options') return response({ publicKey })

        return response({ ok: true })
      }

      #{registration_controller_source}
      controller.connect()
      await new Promise((resolve) => setTimeout(resolve, 0))
      await controller.register({ preventDefault: () => {} })

      process.stdout.write(JSON.stringify({
        requestUrls,
        requestsAfterReload,
        credentialCreateCalls,
        reloadCalls,
        buttonDisabled: controller.buttonTarget.disabled,
        buttonLoading: buttonClasses.has('opacity-60')
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["requestUrls"]).to eq([ "/passkey/options", "/passkey" ])
      expect(result["requestsAfterReload"]).to be_empty
      expect(result["credentialCreateCalls"]).to eq(1)
      expect(result["reloadCalls"]).to eq(1)
      expect(result["buttonDisabled"]).to be(true)
      expect(result["buttonLoading"]).to be(true)
    end
  end

  it "create失敗時はbuttonを再有効化し、準備し直したoptionsで再試行できる" do
    result = run_controller_script(<<~JAVASCRIPT)
      const requestUrls = []
      let createCalls = 0
      let credentialCreateCalls = 0
      let reloadCalls = 0
      const response = (ok, payload) => ({ ok, json: async () => payload })
      const publicKey = {
        challenge: 'AQ',
        user: { id: 'Ag' },
        excludeCredentials: []
      }
      #{registration_credential_source}

      globalThis.document = { querySelector: () => ({ content: 'csrf-token' }) }
      Object.defineProperty(globalThis, 'navigator', {
        configurable: true,
        value: {
          credentials: {
            create: async () => {
              credentialCreateCalls += 1
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
          assign: () => {},
          reload: () => { reloadCalls += 1 }
        }
      }
      globalThis.fetch = async (url) => {
        requestUrls.push(url)
        if (url === '/passkey/options') return response(true, { publicKey })

        createCalls += 1
        if (createCalls === 1) return response(false, { error: 'temporary create failure' })

        return response(true, { ok: true })
      }

      #{registration_controller_source}
      controller.connect()
      await new Promise((resolve) => setTimeout(resolve, 0))
      await controller.register({ preventDefault: () => {} })
      await new Promise((resolve) => setTimeout(resolve, 0))
      const afterFailure = {
        disabled: controller.buttonTarget.disabled,
        loading: buttonClasses.has('opacity-60'),
        errorText: controller.errorTarget.textContent,
        errorHidden: hiddenErrorClasses.has('hidden')
      }

      await controller.register({ preventDefault: () => {} })

      process.stdout.write(JSON.stringify({
        requestUrls,
        credentialCreateCalls,
        reloadCalls,
        afterFailure,
        finalDisabled: controller.buttonTarget.disabled,
        finalLoading: buttonClasses.has('opacity-60')
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["requestUrls"]).to eq([
        "/passkey/options",
        "/passkey",
        "/passkey/options",
        "/passkey"
      ])
      expect(result["credentialCreateCalls"]).to eq(2)
      expect(result["reloadCalls"]).to eq(1)
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
