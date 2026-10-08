# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "spec_helper"

RSpec.shared_examples "an image preview source owner" do |controller_name|
  let(:source) { File.read(File.expand_path("../../app/javascript/controllers/#{controller_name}_controller.js", __dir__)) }

  def run_preview_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class PreviewController extends Controller')
      eval(`${source}\nglobalThis.PreviewController = PreviewController`)

      function buildPreview ({ persisted = '/saved-image.jpg' } = {}) {
        const events = []
        const released = []
        let nextUrl = 0
        let assignments = 0
        let imageSource = persisted
        const classes = new Set(['hidden'])
        const image = {
          dataset: { persistedUrl: persisted },
          get src () { return imageSource },
          set src (value) { assignments += 1; imageSource = value },
          getAttribute: (name) => name === 'src' ? imageSource : null,
          removeAttribute (name) { if (name === 'src') imageSource = '' },
          classList: {
            add: (name) => classes.add(name),
            remove: (name) => classes.delete(name),
            toggle: (name, force) => force ? classes.add(name) : classes.delete(name)
          }
        }
        URL.createObjectURL = () => `blob:selected-${++nextUrl}`
        URL.revokeObjectURL = (url) => released.push({ url, currentSource: imageSource })
        const input = {
          files: [],
          set value (value) { if (value === '') this.files = [] }
        }
        const removeCheckbox = { checked: false }
        const controller = Object.create(PreviewController.prototype)
        Object.defineProperties(controller, {
          hasImageTarget: { value: true },
          imageTarget: { value: image },
          hasInputTarget: { value: true },
          inputTarget: { value: input },
          hasRemoveCheckboxTarget: { value: true },
          removeCheckboxTarget: { value: removeCheckbox },
          hasErrorTarget: { value: false },
          hasErrorTextTarget: { value: false },
          maxFileSizeBytesValue: { value: 1000 },
          invalidTypeMessageValue: { value: 'invalid' },
          fileTooLargeMessageValue: { value: 'too large' }
        })
        controller.dispatch = (name, options) => events.push({ name, fromImage: options.target === image, source: imageSource })
        const snapshot = () => ({ source: imageSource, hidden: classes.has('hidden'), assignments, fileCount: input.files.length })
        return { controller, image, input, removeCheckbox, events, released, snapshot }
      }

      #{script}
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "announces its current source from the image without resetting image visibility or reassigning the URL" do
    result = run_preview_script(<<~JAVASCRIPT)
      const { controller, image, events, snapshot } = buildPreview()
      image.classList.remove('hidden')
      controller.connect()
      controller.refreshPreview()
      process.stdout.write(JSON.stringify({ ...snapshot(), events }))
    JAVASCRIPT

    expect(result).to eq(
      "source" => "/saved-image.jpg", "hidden" => false, "assignments" => 0, "fileCount" => 0,
      "events" => [
        { "name" => "source-changed", "fromImage" => true, "source" => "/saved-image.jpg" },
        { "name" => "source-changed", "fromImage" => true, "source" => "/saved-image.jpg" }
      ]
    )
  end

  it "replaces selected files before releasing their old URL and keeps the current selection on refresh" do
    result = run_preview_script(<<~JAVASCRIPT)
      const { controller, input, removeCheckbox, released, snapshot } = buildPreview()
      controller.connect()
      input.files = [{ type: 'image/png', size: 100 }]
      removeCheckbox.checked = true
      controller.preview()
      input.files = [{ type: 'image/jpeg', size: 200 }]
      controller.preview()
      controller.refreshPreview()
      process.stdout.write(JSON.stringify({ ...snapshot(), released, removed: removeCheckbox.checked }))
    JAVASCRIPT

    expect(result).to eq(
      "source" => "blob:selected-2", "hidden" => true, "assignments" => 2, "fileCount" => 1,
      "released" => [ { "url" => "blob:selected-1", "currentSource" => "blob:selected-2" } ],
      "removed" => false
    )
  end

  it "restores the persisted source and releases the selection after the file input is cleared" do
    result = run_preview_script(<<~JAVASCRIPT)
      const { controller, input, released, snapshot } = buildPreview()
      controller.connect()
      input.files = [{ type: 'image/png', size: 100 }]
      controller.preview()
      input.files = []
      controller.preview()
      process.stdout.write(JSON.stringify({ ...snapshot(), released }))
    JAVASCRIPT

    expect(result).to include(
      "source" => "/saved-image.jpg", "fileCount" => 0,
      "released" => [ { "url" => "blob:selected-1", "currentSource" => "/saved-image.jpg" } ]
    )
  end

  it "restores the selected file with a fresh URL on reconnect" do
    result = run_preview_script(<<~JAVASCRIPT)
      const { controller, input, released, snapshot } = buildPreview({ persisted: '' })
      controller.connect()
      input.files = [{ type: 'image/png', size: 100 }]
      controller.preview()
      controller.disconnect()
      controller.connect()
      process.stdout.write(JSON.stringify({ ...snapshot(), released }))
    JAVASCRIPT

    expect(result).to include(
      "source" => "blob:selected-2", "fileCount" => 1,
      "released" => [ { "url" => "blob:selected-1", "currentSource" => "" } ]
    )
  end

  it "notifies the display owner when removal clears the source" do
    result = run_preview_script(<<~JAVASCRIPT)
      const { controller, input, removeCheckbox, events, snapshot } = buildPreview()
      controller.connect()
      input.files = [{ type: 'image/png', size: 100 }]
      controller.preview()
      removeCheckbox.checked = true
      controller.toggleRemove()
      process.stdout.write(JSON.stringify({ ...snapshot(), event: events.at(-1) }))
    JAVASCRIPT

    expect(result).to include(
      "source" => "", "fileCount" => 0,
      "event" => { "name" => "source-changed", "fromImage" => true, "source" => "" }
    )
  end
end

RSpec.describe "Avatar preview Stimulus controller" do
  include_examples "an image preview source owner", "avatar_preview"
end

RSpec.describe "Attachment preview Stimulus controller" do
  include_examples "an image preview source owner", "attachment_preview"
end

RSpec.describe "Cached image preview sources" do
  it "restores incoming persisted sources before render without changing the visible document" do
    source = File.read(File.expand_path("../../app/javascript/application.js", __dir__))
    encoded_source = Base64.strict_encode64(source)
    script = <<~JAVASCRIPT
      const listeners = new Map()
      globalThis.document = { addEventListener: (name, callback) => listeners.set(name, callback) }
      globalThis.window = { addEventListener () {} }
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8').replace(/^import .+$/gm, '')
      eval(source)
      function image (persistedUrl) {
        return {
          dataset: { persistedUrl }, src: 'blob:released',
          setAttribute (name, value) { this[name] = value },
          removeAttribute (name) { delete this[name] }
        }
      }
      const saved = image('/saved-image.jpg')
      const empty = image('')
      const visible = image('/visible.jpg')
      const newBody = {
        querySelectorAll (selector) {
          if (selector !== 'img[data-persisted-url][src^="blob:"]') throw new Error('Unexpected scope')
          return [saved, empty]
        }
      }
      listeners.get('turbo:before-render')({ detail: { newBody } })
      process.stdout.write(JSON.stringify({ saved: saved.src, empty: empty.src || null, visible: visible.src }))
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script)
    raise stderr unless status.success?

    expect(JSON.parse(stdout)).to eq("saved" => "/saved-image.jpg", "empty" => nil, "visible" => "blob:released")
  end
end
