# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Segmented control and settings Stimulus controllers" do
  let(:segmented_source) { Rails.root.join("app/javascript/controllers/segmented_control_controller.js").read }
  let(:settings_source) { Rails.root.join("app/javascript/controllers/settings_controller.js").read }

  def run_controller_script(script)
    encoded_segmented_source = Base64.strict_encode64(segmented_source)
    encoded_settings_source = Base64.strict_encode64(settings_source)
    harness = <<~JAVASCRIPT
      class Controller {}

      const segmentedSource = Buffer.from(#{encoded_segmented_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", '')
        .replace('export default class extends Controller', 'class SegmentedControlController extends Controller')
      const settingsSource = Buffer.from(#{encoded_settings_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", '')
        .replace('export default class extends Controller', 'class SettingsController extends Controller')

      eval(`${segmentedSource}\nglobalThis.SegmentedControlController = SegmentedControlController`)
      eval(`${settingsSource}\nglobalThis.SettingsController = SettingsController`)

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

  it "renders a 422 Turbo Stream then restores the committed radio and indicator without a console error" do
    result = run_controller_script(<<~JAVASCRIPT)
      const renderedStreams = []
      const dispatchedEvents = []
      const consoleErrors = []
      const originalConsoleError = console.error
      console.error = (...args) => consoleErrors.push(args.join(' '))

      globalThis.document = {
        querySelector: () => ({ content: 'csrf-token' })
      }
      globalThis.window = {
        Turbo: {
          renderStreamMessage: (body) => renderedStreams.push(body)
        }
      }
      globalThis.fetch = async () => ({
        ok: false,
        status: 422,
        text: async () => '<turbo-stream action="update" target="flash"></turbo-stream>'
      })

      const inputs = [
        { value: 'system', checked: true },
        { value: 'light', checked: false }
      ]
      const activeIndexes = []
      const controller = Object.create(SegmentedControlController.prototype)
      controller.inputTargets = inputs
      controller.element = {
        style: {
          setProperty: (_name, value) => activeIndexes.push(value)
        }
      }
      controller.remoteValue = true
      controller.hasUrlValue = true
      controller.hasNameValue = true
      controller.urlValue = '/settings'
      controller.nameValue = 'theme_preference'
      controller.methodValue = 'PATCH'
      controller.dispatch = (name, options) => dispatchedEvents.push({ name, detail: options.detail })

      controller.connect()
      inputs[0].checked = false
      inputs[1].checked = true
      await controller.update({ currentTarget: inputs[1] })
      await new Promise((resolve) => setTimeout(resolve, 0))
      console.error = originalConsoleError

      process.stdout.write(JSON.stringify({
        checked: inputs.map((input) => input.checked),
        activeIndex: activeIndexes.at(-1),
        renderedStreams,
        dispatchedEvents,
        consoleErrors
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["checked"]).to eq([ true, false ])
      expect(result["activeIndex"]).to eq(0)
      expect(result["renderedStreams"]).to eq([ '<turbo-stream action="update" target="flash"></turbo-stream>' ])
      expect(result["dispatchedEvents"]).to eq([
        {
          "name" => "failure",
          "detail" => {
            "name" => "theme_preference",
            "value" => "light",
            "previousValue" => "system",
            "status" => 422
          }
        }
      ])
      expect(result["consoleErrors"]).to be_empty
    end
  end

  it "commits and dispatches a successful setting only after a successful response" do
    result = run_controller_script(<<~JAVASCRIPT)
      const dispatchedEvents = []
      const themeEvents = []
      globalThis.CustomEvent = class {
        constructor (type) { this.type = type }
      }
      globalThis.document = {
        querySelector: () => ({ content: 'csrf-token' }),
        documentElement: { dataset: { theme: 'system' } }
      }
      globalThis.window = {
        Turbo: { renderStreamMessage: () => {} },
        dispatchEvent: (event) => themeEvents.push(event.type)
      }
      globalThis.fetch = async () => ({
        ok: true,
        status: 200,
        text: async () => '<turbo-stream action="update" target="flash"></turbo-stream>'
      })

      const inputs = [
        { value: 'system', checked: true },
        { value: 'light', checked: false }
      ]
      const controller = Object.create(SegmentedControlController.prototype)
      const settingsController = Object.create(SettingsController.prototype)
      controller.inputTargets = inputs
      controller.element = { style: { setProperty: () => {} } }
      controller.remoteValue = true
      controller.hasUrlValue = true
      controller.hasNameValue = true
      controller.urlValue = '/settings'
      controller.nameValue = 'theme_preference'
      controller.methodValue = 'PATCH'
      controller.dispatch = (name, options) => {
        dispatchedEvents.push({ name, detail: options.detail })
        if (name === 'success') {
          settingsController.applySegmentedControlSetting({ detail: options.detail })
        }
      }

      controller.connect()
      inputs[0].checked = false
      inputs[1].checked = true
      await controller.update({ currentTarget: inputs[1] })
      await new Promise((resolve) => setTimeout(resolve, 0))

      process.stdout.write(JSON.stringify({
        theme: document.documentElement.dataset.theme,
        dispatchedEvents,
        themeEvents
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["theme"]).to eq("light")
      expect(result["dispatchedEvents"]).to eq([
        {
          "name" => "success",
          "detail" => {
            "name" => "theme_preference",
            "value" => "light",
            "previousValue" => "system"
          }
        }
      ])
      expect(result["themeEvents"]).to eq([ "recify:theme-change" ])
    end
  end

  it "restores the previous theme when the segmented control reports a failure" do
    result = run_controller_script(<<~JAVASCRIPT)
      const themeEvents = []
      globalThis.CustomEvent = class {
        constructor (type) { this.type = type }
      }
      globalThis.document = {
        documentElement: { dataset: { theme: 'light' } }
      }
      globalThis.window = {
        dispatchEvent: (event) => themeEvents.push(event.type)
      }
      const controller = Object.create(SettingsController.prototype)

      controller.restoreSegmentedControlSetting({
        detail: {
          name: 'theme_preference',
          value: 'light',
          previousValue: 'system'
        }
      })

      process.stdout.write(JSON.stringify({
        theme: document.documentElement.dataset.theme,
        themeEvents
      }))
    JAVASCRIPT

    aggregate_failures do
      expect(result["theme"]).to eq("system")
      expect(result["themeEvents"]).to eq([ "recify:theme-change" ])
    end
  end
end
