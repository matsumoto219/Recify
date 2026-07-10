# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Number field Stimulus controller" do
  let(:source_path) { Rails.root.join("app/javascript/controllers/number_field_controller.js") }
  let(:source) { source_path.read }

  def run_controller_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class NumberFieldController extends Controller')

      eval(`${source}\nglobalThis.NumberFieldController = NumberFieldController`)
      #{script}
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "does not expose input or blur normalization methods" do
    aggregate_failures do
      expect(source).not_to include("normalize (event)")
      expect(source).not_to include("finishComposition")
      expect(source).not_to include("sanitizeNumericValue")
    end
  end

  it "preserves intermediate and invalid text because only explicit stepper actions mutate values" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(NumberFieldController.prototype)
      const values = ['1', '1.', '.5', '', '1e2', 'abc12', '12abc']
      process.stdout.write(JSON.stringify(values.map((value) => {
        const input = { value }
        return { before: value, after: input.value }
      })))
    JAVASCRIPT

    expect(result).to all(satisfy { |entry| entry["before"] == entry["after"] })
  end

  it "clamps only an explicit stepper change and never parses mixed text as another number" do
    result = run_controller_script(<<~JAVASCRIPT)
      class TestEvent {
        constructor (type) { this.type = type }
      }
      globalThis.Event = TestEvent
      const events = []
      const input = {
        value: 'abc12',
        step: '1',
        min: '15',
        max: '900',
        dispatchEvent: (event) => events.push(event.type)
      }
      const controller = Object.create(NumberFieldController.prototype)
      Object.defineProperties(controller, {
        hasInputTarget: { value: true },
        inputTarget: { value: input },
        hasDecimalPrecisionValue: { value: false }
      })
      controller.changeValue(1)
      process.stdout.write(JSON.stringify({ value: input.value, events }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["value"]).to eq("15")
      expect(result["events"]).to eq(%w[input change])
    end
  end
end
