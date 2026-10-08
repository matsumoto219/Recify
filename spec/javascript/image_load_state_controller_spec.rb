# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "spec_helper"

RSpec.describe "Image load state Stimulus controller" do
  let(:source) { File.read(File.expand_path("../../app/javascript/controllers/image_load_state_controller.js", __dir__)) }

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

      function buildController ({ source = '/image.jpg', complete = true, width = 320, loadingFallback = false } = {}) {
        const attributes = new Map()
        const events = []
        const image = {
          source,
          complete,
          naturalWidth: width,
          classList: classList('hidden'),
          getAttribute: (name) => name === 'src' ? image.source : null
        }
        const fallback = { classList: classList('hidden') }
        const empty = { classList: classList('hidden') }
        const controller = Object.create(ImageLoadStateController.prototype)
        Object.defineProperties(controller, {
          hasImageTarget: { value: true },
          imageTarget: { value: image },
          hasFallbackTarget: { value: true },
          fallbackTarget: { value: fallback },
          hasEmptyTarget: { value: true },
          emptyTarget: { value: empty },
          fallbackWhileLoadingValue: { value: loadingFallback },
          element: { value: { isConnected: true, setAttribute: (name, value) => attributes.set(name, value) } }
        })
        controller.dispatch = (name, options) => events.push({ name, state: options.detail.state, currentImage: options.detail.image === image })
        const snapshot = () => ({
          state: controller.state,
          publishedState: attributes.get('data-image-load-state-state'),
          imageHidden: image.classList.contains('hidden'),
          fallbackHidden: fallback.classList.contains('hidden'),
          emptyHidden: empty.classList.contains('hidden'),
          busy: attributes.get('aria-busy')
        })
        return { controller, image, events, snapshot }
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

  it "keeps a loaded image visible when repeated cache preparation leaves the current page in place" do
    result = run_controller_script(<<~JAVASCRIPT)
      const attributes = new Map([['aria-busy', 'false']])
      const image = {
        complete: true,
        naturalWidth: 320,
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
      controller.dispatch = () => {}
      controller.beforeCache()
      controller.beforeCache()

      process.stdout.write(JSON.stringify({
        imageHidden: image.classList.contains('hidden'),
        fallbackHidden: fallback.classList.contains('hidden'),
        busy: attributes.get('aria-busy'),
        state: controller.state
      }))
    JAVASCRIPT

    expect(result).to eq(
      "imageHidden" => false,
      "fallbackHidden" => true,
      "busy" => "false",
      "state" => "available"
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

  it "clears a previous failure while its replacement image is loading" do
    result = run_controller_script(<<~JAVASCRIPT)
      const { controller, image, events, snapshot } = buildController({ width: 0 })
      controller.sync()
      image.source = 'blob:replacement'
      image.complete = false
      controller.sync()
      controller.beforeCache()
      process.stdout.write(JSON.stringify({ ...snapshot(), events }))
    JAVASCRIPT

    expect(result).to eq(
      "state" => "loading", "publishedState" => "loading", "imageHidden" => true,
      "fallbackHidden" => true, "emptyHidden" => true, "busy" => "true",
      "events" => [
        { "name" => "unavailable", "state" => "unavailable", "currentImage" => true },
        { "name" => "loading", "state" => "loading", "currentImage" => true }
      ]
    )
  end

  it "hides the previous image while a new source is loading" do
    result = run_controller_script(<<~JAVASCRIPT)
      const { controller, image, snapshot } = buildController({ loadingFallback: true })
      controller.sync()
      image.source = 'blob:replacement'
      image.complete = false
      controller.sync()
      process.stdout.write(JSON.stringify(snapshot()))
    JAVASCRIPT

    expect(result).to eq(
      "state" => "loading", "publishedState" => "loading", "imageHidden" => true,
      "fallbackHidden" => false, "emptyHidden" => true, "busy" => "true"
    )
  end

  it "derives late load and error events from the current image source" do
    result = run_controller_script(<<~JAVASCRIPT)
      const { controller, image, events, snapshot } = buildController()
      controller.sync()
      image.source = 'blob:replacement'
      image.complete = false
      controller.imageLoaded({ currentTarget: image })
      const loading = snapshot()
      image.complete = true
      image.naturalWidth = 640
      controller.imageFailed({ currentTarget: image })
      const available = snapshot()
      image.source = ''
      controller.imageFailed({ currentTarget: image })
      process.stdout.write(JSON.stringify({ loading, available, empty: snapshot(), states: events.map((event) => event.name) }))
    JAVASCRIPT

    aggregate_failures do
      expect(result.fetch("loading")).to include("state" => "loading", "imageHidden" => true, "busy" => "true")
      expect(result.fetch("available")).to include("state" => "available", "imageHidden" => false, "busy" => "false")
      expect(result.fetch("empty")).to include("state" => "empty", "imageHidden" => true, "emptyHidden" => false)
      expect(result.fetch("states")).to eq(%w[available loading available empty])
    end
  end

  it "ignores events from a different image" do
    result = run_controller_script(<<~JAVASCRIPT)
      const { controller, image, events, snapshot } = buildController()
      controller.sync()
      image.naturalWidth = 0
      controller.imageFailed({ currentTarget: {} })
      process.stdout.write(JSON.stringify({ ...snapshot(), eventCount: events.length }))
    JAVASCRIPT

    expect(result).to include("state" => "available", "imageHidden" => false, "eventCount" => 1)
  end

  it "publishes a changed source once even if both sources are already available" do
    result = run_controller_script(<<~JAVASCRIPT)
      const { controller, image, events } = buildController()
      controller.sync()
      image.source = '/replacement.jpg'
      controller.sync()
      controller.imageLoaded({ currentTarget: image })
      controller.beforeCache()
      process.stdout.write(JSON.stringify(events))
    JAVASCRIPT

    expect(result).to eq([
      { "name" => "available", "state" => "available", "currentImage" => true },
      { "name" => "available", "state" => "available", "currentImage" => true }
    ])
  end

  it "reconciles a completed image on reconnect and pageshow synchronization" do
    result = run_controller_script(<<~JAVASCRIPT)
      const { controller, image, events, snapshot } = buildController({ complete: false, width: 0 })
      controller.connect()
      controller.disconnect()
      image.complete = true
      image.naturalWidth = 320
      controller.connect()
      controller.sync()
      queueMicrotask(() => process.stdout.write(JSON.stringify({ ...snapshot(), states: events.map((event) => event.name) })))
    JAVASCRIPT

    expect(result).to include(
      "state" => "available", "publishedState" => "available", "imageHidden" => false,
      "fallbackHidden" => true, "emptyHidden" => true, "busy" => "false",
      "states" => %w[loading available]
    )
  end

  it "does not dispatch a deferred connection update after disconnect" do
    result = run_controller_script(<<~JAVASCRIPT)
      const { controller, image, events } = buildController({ complete: false, width: 0 })
      controller.connect()
      controller.disconnect()
      image.complete = true
      image.naturalWidth = 320
      queueMicrotask(() => process.stdout.write(JSON.stringify(events.map((event) => event.name))))
    JAVASCRIPT

    expect(result).to eq([ "loading" ])
  end
end
