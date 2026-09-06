# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Receipt image card Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/receipt_image_card_controller.js").read }

  def review_link_result(href:, current_hash: "")
    targets = Rails.root.join("app/javascript/receipts/review_targets.js").read.gsub(/^export /, "")
    controller = source
      .sub("import { Controller } from '@hotwired/stimulus'", "class Controller {}")
      .sub(/import \{.*?\} from 'receipts\/review_targets'/m, "")
      .sub("export default class extends Controller", "class ImageCardController extends Controller")
    encoded = Base64.strict_encode64("#{targets}\n#{controller}")
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
        target: { closest: () => ({ getAttribute: () => #{href.to_json} }) },
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

  it "intercepts a new image-review hash and preserves Turbo history state and selected image" do
    result = review_link_result(href: "#receipt-section-image-preview")

    expect(result).to include(
      "prevented" => true, "isOpen" => true, "scrolls" => 1,
      "hash" => "#receipt-section-image-preview", "replacements" => [],
      "available" => true, "objectUrl" => "blob:existing-selection",
      "files" => [ "existing-file" ], "removeImage" => true
    )
    expect(result.fetch("pushes")).to eq([
      { "state" => { "turbo" => { "restorationIdentifier" => "existing" } }, "url" => "#receipt-section-image-preview" }
    ])
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
      expect(open_from_review_target).to be_present
      expect(open_preview).to be_present
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
      expect(source).to include("this.restoreImageControlsForCache()")
    end
  end
end
