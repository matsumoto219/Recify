# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Image load state Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/image_load_state_controller.js").read }

  def run_controller_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class ImageLoadStateController extends Controller')

      eval(`${source}\nglobalThis.ImageLoadStateController = ImageLoadStateController`)

      function classList (...initial) {
        const values = new Set(initial)
        return {
          add: (...names) => names.forEach((name) => values.add(name)),
          remove: (...names) => names.forEach((name) => values.delete(name)),
          contains: (name) => values.has(name),
          toggle: (name, force) => force ? values.add(name) : values.delete(name),
          values: () => [...values]
        }
      }

      #{script}
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "recovers a load event that completed before Stimulus connected" do
    result = run_controller_script(<<~JAVASCRIPT)
      const events = []
      const attributes = new Map([['aria-busy', 'true']])
      const image = {
        complete: true,
        naturalWidth: 320,
        classList: classList('hidden'),
        getAttribute: (name) => name === 'src' ? '/image.jpg' : null
      }
      const fallback = { classList: classList() }
      const controller = Object.create(ImageLoadStateController.prototype)
      Object.defineProperties(controller, {
        hasImageTarget: { value: true },
        imageTarget: { value: image },
        hasFallbackTarget: { value: true },
        fallbackTarget: { value: fallback },
        fallbackWhileLoadingValue: { value: true },
        element: {
          value: {
            isConnected: true,
            setAttribute: (name, value) => attributes.set(name, value)
          }
        }
      })
      controller.dispatch = (name) => events.push(name)
      controller.connect()

      queueMicrotask(() => process.stdout.write(JSON.stringify({
        imageHidden: image.classList.contains('hidden'),
        fallbackHidden: fallback.classList.contains('hidden'),
        busy: attributes.get('aria-busy'),
        events
      })))
    JAVASCRIPT

    expect(result).to eq(
      "imageHidden" => false,
      "fallbackHidden" => true,
      "busy" => "false",
      "events" => [ "available" ]
    )
  end

  it "hides a failed image and can recover when a later URL loads" do
    result = run_controller_script(<<~JAVASCRIPT)
      const events = []
      const attributes = new Map()
      const image = {
        complete: true,
        naturalWidth: 0,
        classList: classList(),
        getAttribute: (name) => name === 'src' ? '/missing.jpg' : null
      }
      const fallback = { classList: classList('hidden') }
      const controller = Object.create(ImageLoadStateController.prototype)
      Object.defineProperties(controller, {
        hasImageTarget: { value: true },
        imageTarget: { value: image },
        hasFallbackTarget: { value: true },
        fallbackTarget: { value: fallback },
        fallbackWhileLoadingValue: { value: false },
        element: { value: { isConnected: true, setAttribute: (name, value) => attributes.set(name, value) } }
      })
      controller.dispatch = (name) => events.push(name)
      controller.connect()

      queueMicrotask(() => {
        controller.imageFailed({ currentTarget: image })
        image.naturalWidth = 640
        controller.imageLoaded({ currentTarget: image })
        controller.imageLoaded({ currentTarget: image })
        process.stdout.write(JSON.stringify({
          imageHidden: image.classList.contains('hidden'),
          fallbackHidden: fallback.classList.contains('hidden'),
          busy: attributes.get('aria-busy'),
          events
        }))
      })
    JAVASCRIPT

    expect(result).to eq(
      "imageHidden" => false,
      "fallbackHidden" => true,
      "busy" => "false",
      "events" => %w[unavailable available]
    )
  end

  it "returns to a safe loading state before Turbo caches the page" do
    result = run_controller_script(<<~JAVASCRIPT)
      const attributes = new Map([['aria-busy', 'false']])
      const image = {
        classList: classList(),
        getAttribute: (name) => name === 'src' ? '/image.jpg' : null
      }
      const fallback = { classList: classList('hidden') }
      const controller = Object.create(ImageLoadStateController.prototype)
      Object.defineProperties(controller, {
        hasImageTarget: { value: true },
        imageTarget: { value: image },
        hasFallbackTarget: { value: true },
        fallbackTarget: { value: fallback },
        fallbackWhileLoadingValue: { value: true },
        element: { value: { setAttribute: (name, value) => attributes.set(name, value) } }
      })
      controller.state = 'available'
      controller.beforeCache()

      process.stdout.write(JSON.stringify({
        imageHidden: image.classList.contains('hidden'),
        fallbackHidden: fallback.classList.contains('hidden'),
        busy: attributes.get('aria-busy'),
        state: controller.state
      }))
    JAVASCRIPT

    expect(result).to eq(
      "imageHidden" => true,
      "fallbackHidden" => false,
      "busy" => "true",
      "state" => nil
    )
  end

  it "distinguishes an absent source from a failed image when both fallbacks exist" do
    result = run_controller_script(<<~JAVASCRIPT)
      const attributes = new Map()
      let imageSource = ''
      const image = {
        complete: true,
        naturalWidth: 0,
        classList: classList('hidden'),
        getAttribute: (name) => name === 'src' ? imageSource : null
      }
      const unavailableFallback = { classList: classList('hidden') }
      const emptyFallback = { classList: classList('hidden') }
      const controller = Object.create(ImageLoadStateController.prototype)
      Object.defineProperties(controller, {
        hasImageTarget: { value: true },
        imageTarget: { value: image },
        hasFallbackTarget: { value: true },
        fallbackTarget: { value: unavailableFallback },
        hasEmptyTarget: { value: true },
        emptyTarget: { value: emptyFallback },
        fallbackWhileLoadingValue: { value: true },
        element: { value: { setAttribute: (name, value) => attributes.set(name, value) } }
      })
      controller.dispatch = () => {}

      controller.sync()
      const withoutSource = {
        imageHidden: image.classList.contains('hidden'),
        unavailableHidden: unavailableFallback.classList.contains('hidden'),
        emptyHidden: emptyFallback.classList.contains('hidden')
      }

      imageSource = '/missing.jpg'
      controller.imageFailed({ currentTarget: image })
      const failedSource = {
        imageHidden: image.classList.contains('hidden'),
        unavailableHidden: unavailableFallback.classList.contains('hidden'),
        emptyHidden: emptyFallback.classList.contains('hidden'),
        busy: attributes.get('aria-busy')
      }

      process.stdout.write(JSON.stringify({ withoutSource, failedSource }))
    JAVASCRIPT

    expect(result).to eq(
      "withoutSource" => {
        "imageHidden" => true,
        "unavailableHidden" => true,
        "emptyHidden" => false
      },
      "failedSource" => {
        "imageHidden" => true,
        "unavailableHidden" => false,
        "emptyHidden" => true,
        "busy" => "false"
      }
    )
  end
end
