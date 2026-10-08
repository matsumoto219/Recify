# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "spec_helper"

RSpec.describe "Receipt image card lifecycle" do
  def run_controller_script(script)
    source = File.read(File.expand_path("../../app/javascript/controllers/receipt_image_card_controller.js", __dir__))
      .gsub(/^import .*? from '[^']+'\n/m, "")
      .sub("export default class extends Controller", "class ImageCardController extends Controller")
    encoded = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      class Controller {}
      eval(Buffer.from(#{encoded.inspect}, 'base64').toString('utf8') + '\\nglobalThis.ImageCardController = ImageCardController')
      function element (attributes = {}, hidden = false) {
        const classes = new Set(hidden ? ['hidden'] : [])
        return {
          attributes: { ...attributes }, dataset: {}, complete: true, naturalWidth: 100,
          classList: {
            add: (name) => classes.add(name), remove: (name) => classes.delete(name),
            contains: (name) => classes.has(name),
            toggle (name, active) { active ? classes.add(name) : classes.delete(name) }
          },
          getAttribute (name) { return this.attributes[name] ?? null },
          setAttribute (name, value) {
            if (name === 'src' && value !== this.attributes.src) { this.complete = false; this.naturalWidth = 0 }
            this.attributes[name] = value
          },
          removeAttribute (name) { delete this.attributes[name] },
          hasAttribute (name) { return name in this.attributes },
          addEventListener () {}, removeEventListener () {}, querySelector () { return null },
          closest () { return null }, focus () {},
          get src () { return this.attributes.src },
          set src (source) { this.attributes.src = source; this.complete = false; this.naturalWidth = 0 }
        }
      }
      globalThis.window = { addEventListener () {}, removeEventListener () {} }
      globalThis.document = {
        body: element(), createComment: () => ({}), addEventListener () {}, removeEventListener () {}
      }
      function buildController () {
        const controller = Object.create(ImageCardController.prototype)
        const image = element({ src: '/stored-image', 'data-image-load-state-target': 'image' })
        const modal = element({}, true)
        const modalImage = element({ src: '/stored-image' })
        const download = element({ href: '/stored-image', tabindex: '-1' }, true)
        download.hidden = true
        Object.assign(controller, {
          element: element(), application: { getControllerForElementAndIdentifier: () => null },
          initiallyOpenValue: false, collapseOnMobileValue: false, reviewTargetValue: '',
          originalSourceValue: '/stored-image', downloadHrefValue: '/stored-image',
          previewLabelValue: 'Enlarge image',
          hasPreviewImageTarget: true, previewImageTarget: image,
          hasPreviewTriggerTarget: true, previewTriggerTarget: element({ 'aria-label': 'Enlarge image' }),
          hasPreviewOverlayTarget: true, previewOverlayTarget: element({}, true),
          hasModalTarget: true, modalTarget: modal,
          hasModalImageTarget: true, modalImageTarget: modalImage,
          hasModalFallbackTarget: true, modalFallbackTarget: element({}, true),
          hasDownloadTarget: true, downloadTarget: download,
          hasUnavailableImageLabelValue: true, unavailableImageLabelValue: 'Unavailable',
          hasFileInputTarget: true, fileInputTarget: { files: [], value: '' },
          hasRemoveImageFieldTarget: true, removeImageFieldTarget: { checked: false },
          storageLimitBytesValue: 0,
          openFromReviewTargetHash () {}, sync () {},
          restoreModal () {}, addModalEventListeners () {}, removeModalEventListeners () {}
        })
        controller.connect()
        return controller
      }
      #{script}
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "keeps a loaded image and its controls available when cache preparation leaves the same DOM visible" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = buildController()
      controller.handleBeforeCache()
      process.stdout.write(JSON.stringify({
        available: controller.imageIsAvailable,
        disabled: controller.previewTriggerTarget.disabled,
        downloadHidden: controller.downloadTarget.hidden,
        downloadHref: controller.downloadTarget.getAttribute('href')
      }))
    JAVASCRIPT

    expect(result).to eq("available" => true, "disabled" => false, "downloadHidden" => false, "downloadHref" => "/stored-image")
  end

  it "keeps the inline preview usable after only the modal image fails" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = buildController()
      controller.modalImageElement.naturalWidth = 0
      controller.handleModalImageError()
      process.stdout.write(JSON.stringify({
        available: controller.imageIsAvailable,
        disabled: controller.previewTriggerTarget.disabled,
        downloadHidden: controller.downloadTarget.hidden,
        modalHidden: controller.modalImageElement.classList.contains('hidden'),
        fallbackVisible: !controller.modalFallbackElement.classList.contains('hidden')
      }))
    JAVASCRIPT

    expect(result).to eq("available" => true, "disabled" => false, "downloadHidden" => false, "modalHidden" => true, "fallbackVisible" => true)
  end

  it "restores the canonical download and label when reconnecting disabled controls" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = buildController()
      controller.imageUnavailable()
      controller.disconnect()
      controller.connect()
      process.stdout.write(JSON.stringify({
        href: controller.downloadTarget.getAttribute('href'),
        tabindex: controller.downloadTarget.getAttribute('tabindex'),
        label: controller.previewTriggerTarget.getAttribute('aria-label'),
        downloadHidden: controller.downloadTarget.hidden
      }))
    JAVASCRIPT

    expect(result).to eq("href" => "/stored-image", "tabindex" => nil, "label" => "Enlarge image", "downloadHidden" => false)
  end

  it "retains a selected file through cache preparation and reconstructs its URL after reconnect" do
    result = run_controller_script(<<~JAVASCRIPT)
      const revoked = []
      let urls = 0
      URL.createObjectURL = () => `blob:selected-${++urls}`
      const controller = buildController()
      URL.revokeObjectURL = (url) => revoked.push({
        url, preview: controller.previewImageTarget.getAttribute('src'),
        modal: controller.modalImageElement.getAttribute('src')
      })
      const file = { name: 'receipt.png', type: 'image/png', size: 1200 }
      controller.fileInputTarget.files = [file]
      controller.previewSelectedImage({ target: controller.fileInputTarget })
      controller.previewImageTarget.complete = true
      controller.previewImageTarget.naturalWidth = 100
      controller.imageAvailable()
      controller.handleBeforeCache()
      const cached = {
        src: controller.previewImageTarget.getAttribute('src'),
        available: controller.imageIsAvailable, revoked: [...revoked],
        sameFile: controller.fileInputTarget.files[0] === file
      }
      controller.disconnect()
      controller.connect()
      process.stdout.write(JSON.stringify({
        cached, src: controller.previewImageTarget.getAttribute('src'),
        modalSrc: controller.modalImageElement.getAttribute('src'), revoked,
        sameFile: controller.fileInputTarget.files[0] === file,
        available: controller.imageIsAvailable
      }))
    JAVASCRIPT

    expect(result).to eq(
      "cached" => { "src" => "blob:selected-1", "available" => true, "revoked" => [], "sameFile" => true },
      "src" => "blob:selected-2", "modalSrc" => "blob:selected-2",
      "revoked" => [ { "url" => "blob:selected-1", "preview" => "/stored-image", "modal" => "/stored-image" } ],
      "sameFile" => true, "available" => false
    )
  end

  it "releases a replaced selection only after both image consumers have moved to the new source" do
    result = run_controller_script(<<~JAVASCRIPT)
      let urls = 0
      const revoked = []
      URL.createObjectURL = () => `blob:selected-${++urls}`
      const controller = buildController()
      URL.revokeObjectURL = (url) => revoked.push({
        url, preview: controller.previewImageTarget.getAttribute('src'),
        modal: controller.modalImageElement.getAttribute('src')
      })
      controller.previewFile({ name: 'first.png', type: 'image/png' })
      controller.previewFile({ name: 'second.png', type: 'image/png' })
      process.stdout.write(JSON.stringify(revoked))
    JAVASCRIPT

    expect(result).to eq([ { "url" => "blob:selected-1", "preview" => "blob:selected-2", "modal" => "blob:selected-2" } ])
  end

  it "restores a persisted source instead of a cached blob when no selected File is available" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = buildController()
      controller.previewImageTarget.setAttribute('src', 'blob:previous-page')
      controller.modalImageElement.setAttribute('src', 'blob:previous-page')
      controller.disconnect()
      controller.connect()
      process.stdout.write(JSON.stringify({
        src: controller.previewImageTarget.getAttribute('src'),
        modalSrc: controller.modalImageElement.getAttribute('src'),
        files: controller.fileInputTarget.files
      }))
    JAVASCRIPT

    expect(result).to eq("src" => "/stored-image", "modalSrc" => "/stored-image", "files" => [])
  end

  it "ignores state notifications for another image and disables controls while its own image loads" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = buildController()
      controller.imageUnavailable({ detail: { image: controller.modalImageElement, state: 'unavailable' } })
      const otherImage = controller.imageIsAvailable
      controller.imageUnavailable({ detail: { image: controller.previewImageTarget, state: 'loading' } })
      const ownLoading = controller.imageIsAvailable
      controller.imageAvailable({ detail: { image: controller.previewImageTarget, state: 'available' } })
      process.stdout.write(JSON.stringify({ otherImage, ownLoading, recovered: controller.imageIsAvailable }))
    JAVASCRIPT

    expect(result).to eq("otherImage" => true, "ownLoading" => false, "recovered" => true)
  end

  it "restores the body lock it owns without clearing an existing lock" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = buildController()
      controller.lockBodyScroll()
      controller.unlockBodyScroll()
      const unlocked = !document.body.classList.contains('overflow-hidden')
      document.body.classList.add('overflow-hidden')
      controller.lockBodyScroll()
      controller.unlockBodyScroll()
      process.stdout.write(JSON.stringify({ unlocked, retained: document.body.classList.contains('overflow-hidden') }))
    JAVASCRIPT

    expect(result).to eq("unlocked" => true, "retained" => true)
  end

  it "ignores a late modal failure event after the current modal image has loaded" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = buildController()
      controller.handleModalImageError()
      process.stdout.write(JSON.stringify({
        visible: !controller.modalImageElement.classList.contains('hidden'),
        fallbackHidden: controller.modalFallbackElement.classList.contains('hidden'),
        available: controller.imageIsAvailable
      }))
    JAVASCRIPT

    expect(result).to eq("visible" => true, "fallbackHidden" => true, "available" => true)
  end

  it "restores the persisted image before revoking a selection cleared by the removal checkbox" do
    result = run_controller_script(<<~JAVASCRIPT)
      const revoked = []
      URL.createObjectURL = () => 'blob:selected'
      const controller = buildController()
      URL.revokeObjectURL = (url) => revoked.push({
        url, preview: controller.previewImageTarget.getAttribute('src'),
        modal: controller.modalImageElement.getAttribute('src')
      })
      controller.previewFile({ name: 'receipt.png', type: 'image/png' })
      controller.removeImageFieldTarget.checked = true
      controller.toggleRemoveImage()
      process.stdout.write(JSON.stringify({ revoked, remove: controller.removeImageFieldTarget.checked, objectUrl: controller.objectUrl }))
    JAVASCRIPT

    expect(result).to eq(
      "revoked" => [ { "url" => "blob:selected", "preview" => "/stored-image", "modal" => "/stored-image" } ],
      "remove" => true, "objectUrl" => nil
    )
  end
end
