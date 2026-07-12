# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Email address copy Stimulus controller" do
  let(:source_path) { Rails.root.join("app/javascript/controllers/email_address_copy_controller.js") }
  let(:source) { source_path.read }

  def run_controller_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class EmailAddressCopyController extends Controller')

      eval(`${source}\nglobalThis.EmailAddressCopyController = EmailAddressCopyController`)
      #{script}
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "同一email表示のfull selectionだけをcanonical値へ置換する" do
    result = run_controller_script(<<~JAVASCRIPT)
      const canonical = 'selection-copy@example.test'
      const display = {
        nodeType: 1,
        dataset: { emailAddressValue: canonical },
        closest: () => display
      }
      const endpoint = {
        nodeType: 3,
        parentElement: { closest: () => display }
      }
      const selection = {
        anchorNode: endpoint,
        focusNode: endpoint,
        isCollapsed: false,
        rangeCount: 1,
        toString: () => 'selection-copy\\n@\\nexample.test'
      }
      const writes = []
      let prevented = false
      globalThis.document = { getSelection: () => selection }
      const controller = Object.create(EmailAddressCopyController.prototype)

      controller.copy({
        clipboardData: { setData: (type, value) => writes.push([type, value]) },
        preventDefault: () => { prevented = true }
      })

      process.stdout.write(JSON.stringify({ writes, prevented }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["writes"]).to eq([ [ "text/plain", "selection-copy@example.test" ] ])
      expect(result["prevented"]).to be(true)
    end
  end

  it "partial・周辺・複数email・collapsed・multi-range選択には介入しない" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(EmailAddressCopyController.prototype)

      const makeDisplay = (value) => {
        const display = {
          nodeType: 1,
          dataset: { emailAddressValue: value },
          closest: () => display
        }
        return display
      }
      const endpointFor = (display) => ({
        nodeType: 3,
        parentElement: { closest: () => display }
      })
      const outsideEndpoint = {
        nodeType: 3,
        parentElement: { closest: () => null }
      }
      const firstDisplay = makeDisplay('first@example.test')
      const secondDisplay = makeDisplay('second@example.test')

      const cases = [
        {
          name: 'partial',
          selection: {
            anchorNode: endpointFor(firstDisplay), focusNode: endpointFor(firstDisplay),
            isCollapsed: false, rangeCount: 1, toString: () => 'first'
          }
        },
        {
          name: 'surrounding',
          selection: {
            anchorNode: outsideEndpoint, focusNode: endpointFor(firstDisplay),
            isCollapsed: false, rangeCount: 1, toString: () => '前 first@example.test'
          }
        },
        {
          name: 'multiple emails',
          selection: {
            anchorNode: endpointFor(firstDisplay), focusNode: endpointFor(secondDisplay),
            isCollapsed: false, rangeCount: 1, toString: () => 'first@example.test second@example.test'
          }
        },
        {
          name: 'collapsed',
          selection: {
            anchorNode: endpointFor(firstDisplay), focusNode: endpointFor(firstDisplay),
            isCollapsed: true, rangeCount: 1, toString: () => ''
          }
        },
        {
          name: 'multi range',
          selection: {
            anchorNode: endpointFor(firstDisplay), focusNode: endpointFor(firstDisplay),
            isCollapsed: false, rangeCount: 2, toString: () => 'first@example.test'
          }
        }
      ]

      const results = cases.map(({ name, selection }) => {
        const writes = []
        let prevented = false
        globalThis.document = { getSelection: () => selection }
        controller.copy({
          clipboardData: { setData: (type, value) => writes.push([type, value]) },
          preventDefault: () => { prevented = true }
        })
        return { name, writes, prevented }
      })

      process.stdout.write(JSON.stringify(results))
    JAVASCRIPT

    expect(result).to all(include("writes" => [], "prevented" => false))
  end
end
