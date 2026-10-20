# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "spec_helper"

RSpec.describe "Receipt image card Stimulus controller" do
  let(:source) { File.read(File.expand_path("../../app/javascript/controllers/receipt_image_card_controller.js", __dir__)) }

  def review_link_result(href:, current_hash: "", prevented: false)
    module_source = %w[review_targets review_navigation].map do |name|
      File.read(File.expand_path("../../app/javascript/receipts/#{name}.js", __dir__)).gsub(/^import .*? from '[^']+'\n/m, "").gsub(/^export /, "")
    end.join("\n")
    controller = source
      .sub("import { Controller } from '@hotwired/stimulus'", "class Controller {}")
      .sub("import { isAllowedImageFile } from 'image_file_type'", "")
      .sub(/import \{.*?\} from 'receipts\/review_targets'/m, "")
      .sub(/import \{.*?\} from 'receipts\/review_navigation'/m, "")
      .sub("export default class extends Controller", "class ImageCardController extends Controller")
    encoded = Base64.strict_encode64("#{module_source}\n#{controller}")
    script = <<~JAVASCRIPT
      eval(Buffer.from(#{encoded.inspect}, 'base64').toString('utf8') + '\\nglobalThis.ImageCardController = ImageCardController')
      let location = new URL('https://example.test/receipts/example/edit#{current_hash}')
      const calls = { pushes: [], replacements: [], scrolls: 0, prevented: false }
      const historyState = { turbo: { restorationIdentifier: 'existing' } }
      globalThis.window = {
        get location () { return location },
        history: {
          state: historyState,
          pushState (state, _title, url) {
            calls.pushes.push({ state, url })
            location = new URL(url, location)
          },
          replaceState (...args) { calls.replacements.push(args) }
        }
      }
      location.replace = (url) => calls.replacements.push(url)
      const element = {}
      globalThis.document = {
        getElementById: (id) => id === 'receipt-section-image-preview' ? { contains: (node) => node === element } : null
      }
      const controller = Object.create(ImageCardController.prototype)
      Object.assign(controller, {
        element,
        reviewTargetValue: 'receipt-section-image-preview',
        imageIsAvailable: true,
        objectUrl: 'blob:existing-selection',
        fileInputTarget: { files: ['existing-file'] },
        removeImageFieldTarget: { checked: true },
        sync () {},
        scrollReviewTargetIntoView () { calls.scrolls += 1 }
      })
      const event = {
        defaultPrevented: #{prevented},
        target: { closest: () => ({ getAttribute: (name) => name === 'href' ? #{href.to_json} : null }) },
        preventDefault () { calls.prevented = true }
      }
      controller.handleReviewTargetClick(event)
      process.stdout.write(JSON.stringify({
        ...calls, hash: window.location.hash, isOpen: controller.isOpen || false,
        available: controller.imageIsAvailable, objectUrl: controller.objectUrl,
        files: controller.fileInputTarget.files, removeImage: controller.removeImageFieldTarget.checked
      }))
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  def run_discard_script(script)
    targets = File.read(File.expand_path("../../app/javascript/receipts/review_targets.js", __dir__)).gsub(/^export /, "")
    file_type_source = File.read(File.expand_path("../../app/javascript/image_file_type.js", __dir__)).gsub(/^export /, "")
    controller = source
      .sub("import { Controller } from '@hotwired/stimulus'", "class Controller {}")
      .sub("import { isAllowedImageFile } from 'image_file_type'") { file_type_source }
      .sub(/import \{.*?\} from 'receipts\/review_targets'/m, "")
      .sub(/import \{.*?\} from 'receipts\/review_navigation'/m, "")
      .sub("export default class extends Controller", "class ImageCardController extends Controller")
    encoded = Base64.strict_encode64("#{targets}\n#{controller}")
    harness = <<~JAVASCRIPT
      eval(Buffer.from(#{encoded.inspect}, 'base64').toString('utf8') + '\\nglobalThis.ImageCardController = ImageCardController')
      globalThis.window = Object.assign(new EventTarget(), { location: new URL('https://example.test/receipts/example/edit') })
      globalThis.document = Object.assign(new EventTarget(), { createComment: () => ({}) })
      function image () {
        const attributes = new Map()
        return Object.assign(new EventTarget(), {
          complete: true, naturalWidth: 100,
          getAttribute: (name) => attributes.get(name) || '',
          setAttribute: (name, value) => attributes.set(name, value),
          removeAttribute: (name) => attributes.delete(name),
          closest: () => null, classList: { toggle () {} }
        })
      }
      function buildPreview (persisted = '/saved-image.jpg') {
        const form = new EventTarget(), preview = image(), modal = image(), released = []
        const input = { form, files: [], set value (value) { if (value === '') this.files = [] } }
        const fileName = { dataset: { initialLabel: 'saved-image.jpg' }, textContent: '', removeAttribute (name) { delete this[name] } }
        URL.createObjectURL = () => 'blob:selected'
        URL.revokeObjectURL = (url) => released.push({ url, currentSource: preview.getAttribute('src') })
        const controller = Object.create(ImageCardController.prototype)
        Object.assign(controller, {
          hasFileInputTarget: true, fileInputTarget: input, hasPreviewImageTarget: true, previewImageTarget: preview,
          hasModalImageTarget: true, modalImageTarget: modal, hasFileNameTarget: true, fileNameTarget: fileName,
          originalSourceValue: persisted, storageLimitBytesValue: 0, reviewTargetValue: '', emptyFileLabelValue: 'No file'
        })
        controller.connect()
        input.files = [{ type: 'image/png', size: 100, name: 'selected.png' }]
        controller.previewSelectedImage({ target: input })
        const snapshot = () => ({
          preview: preview.getAttribute('src'), modal: modal.getAttribute('src'),
          files: input.files.length, fileName: fileName.textContent, objectUrl: controller.objectUrl
        })
        return { controller, form, input, released, snapshot }
      }
      #{script}
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "opens the image preview from image review target hashes without toggling it closed" do
    aggregate_failures do
      expect(source).to include("reviewTarget: String")
      expect(source).to include("document.addEventListener('click', this.handleReviewTargetClick)")
      expect(source).to include("window.addEventListener('hashchange', this.handleReviewTargetHashChange)")
      expect(source).to include("this.openFromReviewTargetHash()")
      expect(source).to include("this.openPreview({ userDirected: true })")
      expect(source).to include("this.isOpen = true")
      expect(source).to include("return this.reviewTargetValue !== '' && targetId === this.reviewTargetValue")
      expect(source).to include("reviewScrollTarget")
      expect(source).to include("const section = document.getElementById(this.reviewTargetValue)")
      expect(source).to include("section.scrollIntoView({ behavior: 'auto', block: 'start', inline: 'nearest' })")
      expect(source).to include("centerReviewScrollTarget")
      expect(source).to include("window.scrollBy({ top: delta, behavior: 'smooth' })")
      expect(source).not_to include("IMAGE_PREVIEW_REVIEW_TARGET = 'receipt-section-image-preview'")
    end
  end

  it "opens an image-review hash and preserves selected files when Turbo is unavailable" do
    result = review_link_result(href: "#receipt-section-image-preview")

    expect(result).to include(
      "prevented" => true, "isOpen" => true, "scrolls" => 1,
      "hash" => "#receipt-section-image-preview", "replacements" => [],
      "available" => true, "objectUrl" => "blob:existing-selection",
      "files" => [ "existing-file" ], "removeImage" => true
    )
    expect(result.fetch("pushes")).to eq([])
  end

  it "reopens the same hash without replacing or adding history" do
    result = review_link_result(href: "#receipt-section-image-preview", current_hash: "#receipt-section-image-preview")

    expect(result).to include(
      "prevented" => true,
      "isOpen" => true,
      "scrolls" => 1,
      "pushes" => [],
      "replacements" => []
    )
  end

  it "leaves clicks already handled by the form to the common navigation owner" do
    expect(review_link_result(href: "#receipt-section-image-preview", prevented: true)).to include(
      "prevented" => false, "isOpen" => false, "pushes" => [], "replacements" => []
    )
  end

  it "leaves other sections, receipts and origins to their normal navigation" do
    [
      "#receipt-section-items",
      "/receipts/other/edit#receipt-section-image-preview",
      "https://other.test/receipts/example/edit#receipt-section-image-preview"
    ].each do |href|
      expect(review_link_result(href:)).to include(
        "prevented" => false,
        "isOpen" => false,
        "pushes" => [],
        "replacements" => []
      )
    end
  end

  it "keeps selected files and remove-image requests untouched while opening from review links" do
    open_from_review_target = source[/openFromReviewTarget \(\{ scroll = true \} = \{\}\) \{.*?^\s+\}/m]
    open_preview = source[/openPreview \(\{ userDirected = false \} = \{\}\) \{.*?^\s+\}/m]

    aggregate_failures do
      expect(open_from_review_target).not_to be_nil
      expect(open_preview).not_to be_nil
      expect(open_from_review_target).not_to include("clearFileInput")
      expect(open_from_review_target).not_to include("clearRemoveImageRequest")
      expect(open_preview).not_to include("clearFileInput")
      expect(open_preview).not_to include("clearRemoveImageRequest")
    end
  end

  it "disables image actions after a load failure and restores them only after a successful load" do
    aggregate_failures do
      expect(source).to include("imageUnavailable")
      expect(source).to include("imageAvailable")
      expect(source).to include("this.previewTriggerTarget.disabled = true")
      expect(source).to include("this.downloadTarget.removeAttribute('href')")
      expect(source).to include("this.downloadTarget.hidden = true")
      expect(source).to include("this.previewTriggerTarget.setAttribute('aria-label', this.unavailableImageLabelValue)")
      expect(source).to include("if (!this.imageIsAvailable) return")
    end
  end

  it "restores saved preview sources and file label before releasing a discarded selection" do
    result = run_discard_script(<<~JAVASCRIPT)
      const { form, input, released, snapshot } = buildPreview()
      input.value = ''
      form.dispatchEvent(new Event('upload-guard:discard'))
      process.stdout.write(JSON.stringify({ ...snapshot(), released }))
    JAVASCRIPT

    expect(result).to eq(
      "preview" => "/saved-image.jpg", "modal" => "/saved-image.jpg", "files" => 0,
      "fileName" => "saved-image.jpg", "objectUrl" => nil,
      "released" => [ { "url" => "blob:selected", "currentSource" => "/saved-image.jpg" } ]
    )
  end

  it "removes discarded preview sources when no saved image exists" do
    result = run_discard_script(<<~JAVASCRIPT)
      const { form, input, released, snapshot } = buildPreview('')
      input.value = ''
      form.dispatchEvent(new Event('upload-guard:discard'))
      process.stdout.write(JSON.stringify({ ...snapshot(), released }))
    JAVASCRIPT

    expect(result).to include(
      "preview" => "", "modal" => "", "files" => 0, "objectUrl" => nil,
      "released" => [ { "url" => "blob:selected", "currentSource" => "" } ]
    )
  end

  it "ignores other forms and removes its discard listener when disconnected" do
    result = run_discard_script(<<~JAVASCRIPT)
      const { controller, form, released, snapshot } = buildPreview()
      new EventTarget().dispatchEvent(new Event('upload-guard:discard'))
      const unrelated = { ...snapshot(), released: released.length }
      controller.disconnect()
      controller.fileNameTarget.textContent = 'untouched'
      form.dispatchEvent(new Event('upload-guard:discard'))
      process.stdout.write(JSON.stringify({ unrelated, fileName: controller.fileNameTarget.textContent }))
    JAVASCRIPT

    expect(result.fetch("unrelated")).to include("preview" => "blob:selected", "modal" => "blob:selected", "files" => 1, "released" => 0)
    expect(result.fetch("fileName")).to eq("untouched")
  end
end
