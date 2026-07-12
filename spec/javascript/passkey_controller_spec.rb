# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Passkey Stimulus controller" do
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

      const controller = Object.create(PasskeyController.prototype)
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
        credentialCreateCalls
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["redirectsAfterPreload"]).to be_empty
      expect(result["redirects"]).to eq([ "/settings/security/reauthentication/new" ])
      expect(result["fetchCalls"]).to eq(1)
      expect(result["credentialCreateCalls"]).to eq(0)
    end
  end
end
