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

  it "increments large decimal source values without binary floating-point drift" do
    result = run_controller_script(<<~JAVASCRIPT)
      class TestEvent {
        constructor (type) { this.type = type }
      }
      globalThis.Event = TestEvent
      const input = {
        value: '999999999998.999999',
        step: '1',
        min: '0',
        max: '999999999999.999999',
        dispatchEvent: () => {}
      }
      const controller = Object.create(NumberFieldController.prototype)
      Object.defineProperties(controller, {
        hasInputTarget: { value: true },
        inputTarget: { value: input },
        hasDecimalPrecisionValue: { value: true },
        decimalPrecisionValue: { value: 6 }
      })

      controller.changeValue(-1)
      const decremented = input.value
      controller.changeValue(1)

      process.stdout.write(JSON.stringify({ decremented, incremented: input.value }))
    JAVASCRIPT

    expect(result).to eq(
      "decremented" => "999999999997.999999",
      "incremented" => "999999999998.999999"
    )
  end

  it "keeps decimal step rounding exact" do
    result = run_controller_script(<<~JAVASCRIPT)
      class TestEvent {
        constructor (type) { this.type = type }
      }
      globalThis.Event = TestEvent
      const input = {
        value: '9.95',
        step: '0.1',
        min: '0',
        max: '100',
        dispatchEvent: () => {}
      }
      const controller = Object.create(NumberFieldController.prototype)
      Object.defineProperties(controller, {
        hasInputTarget: { value: true },
        inputTarget: { value: input },
        hasDecimalPrecisionValue: { value: true },
        decimalPrecisionValue: { value: 1 }
      })

      controller.changeValue(1)
      process.stdout.write(JSON.stringify({ value: input.value }))
    JAVASCRIPT

    expect(result).to eq("value" => "10.1")
  end

  it "preserves the accepted two-decimal tax rate while stepping by one tenth" do
    result = run_controller_script(<<~JAVASCRIPT)
      class TestEvent {
        constructor (type) { this.type = type }
      }
      globalThis.Event = TestEvent
      const input = {
        value: '10.55',
        step: '0.1',
        min: '0',
        max: '100',
        dispatchEvent: () => {}
      }
      const controller = Object.create(NumberFieldController.prototype)
      Object.defineProperties(controller, {
        hasInputTarget: { value: true },
        inputTarget: { value: input },
        hasDecimalPrecisionValue: { value: true },
        decimalPrecisionValue: { value: 2 }
      })

      controller.changeValue(1)
      const incremented = input.value
      controller.changeValue(-1)
      controller.changeValue(-1)

      process.stdout.write(JSON.stringify({ incremented, decremented: input.value }))
    JAVASCRIPT

    expect(result).to eq("incremented" => "10.65", "decremented" => "10.45")
  end

  it "increments grouped and full-width decimal amounts from their exact current values" do
    result = run_controller_script(<<~JAVASCRIPT)
      class TestEvent {
        constructor (type) { this.type = type }
      }
      globalThis.Event = TestEvent
      const controller = Object.create(NumberFieldController.prototype)
      Object.defineProperties(controller, {
        hasInputTarget: { value: true },
        hasDecimalPrecisionValue: { value: true },
        decimalPrecisionValue: { value: 6 },
        hasDecimalCommaValue: { value: false },
        decimalCommaValue: { value: false }
      })
      const values = ['1,000', '１，０００．５']
      const stepped = values.map((value) => {
        const input = {
          value,
          step: '1',
          min: '0',
          max: '999999999999',
          dispatchEvent: () => {}
        }
        Object.defineProperty(controller, 'inputTarget', { configurable: true, value: input })
        controller.changeValue(1)
        return input.value
      })

      process.stdout.write(JSON.stringify(stepped))
    JAVASCRIPT

    expect(result).to eq(%w[1001 1001.5])
  end

  it "keeps decimal-comma percentage semantics when a stepper is explicitly configured for them" do
    result = run_controller_script(<<~JAVASCRIPT)
      class TestEvent {
        constructor (type) { this.type = type }
      }
      globalThis.Event = TestEvent
      const input = {
        value: '10,55',
        step: '0.1',
        min: '0',
        max: '100',
        dispatchEvent: () => {}
      }
      const controller = Object.create(NumberFieldController.prototype)
      Object.defineProperties(controller, {
        hasInputTarget: { value: true },
        inputTarget: { value: input },
        hasDecimalPrecisionValue: { value: true },
        decimalPrecisionValue: { value: 2 },
        hasDecimalCommaValue: { value: true },
        decimalCommaValue: { value: true }
      })

      controller.changeValue(1)
      process.stdout.write(JSON.stringify({ value: input.value }))
    JAVASCRIPT

    expect(result).to eq("value" => "10.65")
  end
end
