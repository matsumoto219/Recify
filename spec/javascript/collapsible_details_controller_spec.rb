# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Collapsible details Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/collapsible_details_controller.js").read }

  def run_controller_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class CollapsibleDetailsController extends Controller')

      eval(`${source}\nglobalThis.CollapsibleDetailsController = CollapsibleDetailsController`)
      #{script}
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "opens a closed disclosure synchronously when a required descendant is invalid" do
    result = run_controller_script(<<~JAVASCRIPT)
      globalThis.window = { matchMedia: () => ({ matches: true }) }
      const invalidInput = {}
      const content = {
        contains: (candidate) => candidate === invalidInput,
        toggleAttribute: () => {},
        setAttribute: () => {}
      }
      const controller = Object.create(CollapsibleDetailsController.prototype)
      const element = { open: false, dataset: { collapsibleOpen: 'false' } }
      Object.assign(controller, { element })
      Object.defineProperties(controller, {
        hasContentTarget: { value: true },
        contentTarget: { value: content }
      })
      controller.closeTimer = null
      controller.openFrame = null

      controller.handleInvalid({ target: invalidInput })

      process.stdout.write(JSON.stringify({
        open: element.open,
        openState: element.dataset.collapsibleOpen
      }))
    JAVASCRIPT

    expect(result).to eq("open" => true, "openState" => "true")
  end

  it "does not change disclosure state for an invalid control outside its content" do
    result = run_controller_script(<<~JAVASCRIPT)
      const content = { contains: () => false }
      const controller = Object.create(CollapsibleDetailsController.prototype)
      const element = { open: false, dataset: { collapsibleOpen: 'false' } }
      Object.assign(controller, { element })
      Object.defineProperties(controller, {
        hasContentTarget: { value: true },
        contentTarget: { value: content }
      })

      controller.handleInvalid({ target: {} })

      process.stdout.write(JSON.stringify({
        open: element.open,
        openState: element.dataset.collapsibleOpen
      }))
    JAVASCRIPT

    expect(result).to eq("open" => false, "openState" => "false")
  end
end
