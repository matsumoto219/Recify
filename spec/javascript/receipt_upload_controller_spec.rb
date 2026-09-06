# frozen_string_literal: true

require "base64"
require "json"
require "open3"

RSpec.describe "Receipt upload camera controller" do
  let(:source) { File.read(File.expand_path("../../app/javascript/controllers/receipt_upload_controller.js", __dir__)) }

  def run_upload_script(script)
    camera = File.read(File.expand_path("../../app/javascript/receipts/camera_capture.js", __dir__)).gsub(/^export /, "")
    controller = source
      .sub("import { Controller } from '@hotwired/stimulus'", "class Controller {}")
      .sub("import { CameraCapture, supportsInlineCamera } from 'receipts/camera_capture'", "")
      .sub("export default class extends Controller", "class ReceiptUploadController extends Controller")
    encoded = Base64.strict_encode64("#{camera}\n#{controller}")
    harness = <<~JAVASCRIPT
      eval(Buffer.from(#{encoded.inspect}, 'base64').toString('utf8') + '\\nglobalThis.ReceiptUploadController = ReceiptUploadController\\nglobalThis.cameraGuideBounds = cameraGuideBounds')
      function node () {
        const element = new EventTarget(), classes = new Set(), attributes = new Map(), styles = new Map()
        Object.assign(element, {
          classList: {
            add: (...names) => names.forEach((name) => classes.add(name)),
            remove: (...names) => names.forEach((name) => classes.delete(name)),
            toggle: (name, state) => state ? classes.add(name) : classes.delete(name),
            contains: (name) => classes.has(name)
          },
          setAttribute: (name, value) => attributes.set(name, value), getAttribute: (name) => attributes.get(name), removeAttribute: (name) => attributes.delete(name),
          toggleAttribute: (name, present) => present ? attributes.set(name, '') : attributes.delete(name),
          hasAttribute: (name) => attributes.has(name), contains (child) { return child === this || this.children.includes(child) },
          closest: () => null, querySelector: () => null, getBoundingClientRect: () => ({ left: 0, top: 0, height: 400, width: 600 }),
          style: { setProperty: (name, value) => styles.set(name, value), removeProperty: (name) => styles.delete(name), getPropertyValue: (name) => styles.get(name) || '' },
          children: [], replaceChildren () { this.children = [] }, appendChild (child) { this.children.push(child) },
          dataset: {}, textContent: '', disabled: false, clicks: 0, click () { this.clicks += 1 }, focus () { this.focused = true; document.activeElement = this },
          readyState: 2, videoWidth: 640, videoHeight: 480, srcObject: null, async play () {}, pause () {},
          getContext: () => ({ drawImage () {} }), toBlob: (callback, type) => callback(new Blob(['jpeg'], { type }))
        })
        let files = [], value = ''
        Object.defineProperties(element, {
          files: { get: () => files, set: (next) => { if (element.assignmentFails) throw new Error('private detail'); files = next } },
          value: { get: () => value, set: (next) => { value = next; if (next === '') files = [] } }
        })
        return element
      }
      function stream (deviceId = 'private-device') {
        const track = Object.assign(new EventTarget(), {
          readyState: 'live', stopped: 0, stop () { this.stopped += 1; this.readyState = 'ended' },
          getSettings: () => ({ deviceId })
        })
        return { track, getTracks: () => [track], getVideoTracks: () => [track] }
      }
      function deferred () {
        let resolve, reject
        const promise = new Promise((yes, no) => { resolve = yes; reject = no })
        return { promise, resolve, reject }
      }
      function setup (mediaDevices = { async getUserMedia () { return stream() }, async enumerateDevices () { return [] } }) {
        const timers = new Map()
        let clock = 0, timerId = 0
        globalThis.window = Object.assign(new EventTarget(), {
          isSecureContext: true, innerHeight: 1200, scrollY: 0,
          matchMedia: (query) => ({ matches: query !== '(prefers-reduced-motion: reduce)' }),
          getComputedStyle: () => ({ paddingBottom: '40px', minHeight: '320px', strokeWidth: '4px' }),
          setTimeout (callback, delay) { const id = ++timerId; timers.set(id, { callback, at: clock + delay }); return id },
          clearTimeout: (id) => timers.delete(id),
          requestAnimationFrame (callback) { return this.setTimeout(callback, 0) },
          cancelAnimationFrame (id) { this.clearTimeout(id) },
          advance (duration) {
            const end = clock + duration
            for (let timer; (timer = [...timers].filter(([, value]) => value.at <= end).sort((left, right) => left[1].at - right[1].at)[0]);) {
              const [id, value] = timer
              timers.delete(id)
              clock = value.at
              value.callback()
            }
            clock = end
          },
          timers
        })
        globalThis.document = Object.assign(new EventTarget(), { hidden: false, createElement: () => node(), querySelector: () => null })
        Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { mediaDevices } })
        globalThis.DataTransfer = class {
          constructor () { this.files = []; this.items = { add: (file) => this.files.push(file) } }
        }
        URL.createObjectURL = () => 'blob:synthetic-preview'
        URL.revokeObjectURL = () => {}
        const controller = new ReceiptUploadController()
        for (const target of ReceiptUploadController.targets) {
          controller[`${target}Target`] = node()
          controller[`has${target[0].toUpperCase()}${target.slice(1)}Target`] = true
        }
        const guide = node()
        guide.getBoundingClientRect = () => ({ left: 200, top: 100, width: 100, height: 150 })
        controller.cameraGuideTarget.querySelector = (selector) => selector === '[data-camera-guide]' ? guide : node()
        Object.assign(controller, {
          element: node(), ocrAvailableValue: true, maxFileCountValue: 5,
          invalidImageMessageValue: 'invalid image', quotaExceededMessageValue: 'quota', maxFileCountMessageValue: 'count',
          emptyFileMessageValue: 'empty', selectedFilesMessageValue: '%{count}: %{files}', previewCounterMessageValue: '%{current}/%{total}',
          storageUsedBytesValue: 0, storageLimitBytesValue: 0,
          cameraMessagesValue: {
            requesting: { title: 'requesting', help: 'permission prompt' },
            permission: { title: 'permission', help: 'allow camera' },
            unavailable: { title: 'unavailable', help: 'check camera' },
            capture: { title: 'capture', help: 'retry capture' }
          },
          cameraDeviceLabelValue: 'Camera %{number}'
        })
        controller.connect()
        return controller
      }
      function selectPrior (controller) {
        const prior = new File(['prior'], 'prior.png', { type: 'image/png' })
        controller.cameraInputTarget.files = [prior]
        controller.previewCamera()
        return prior
      }
      async function run () { #{script} }
      run().then((result) => process.stdout.write(JSON.stringify(result))).catch((error) => { console.error(error); process.exitCode = 1 })
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "opens an inline video only after an explicit click and disables submit while it is open" do
    result = run_upload_script(<<~JAVASCRIPT)
      const calls = [], cameraStream = stream()
      const controller = setup({ async getUserMedia (constraints) { calls.push(constraints); return cameraStream }, async enumerateDevices () { return [] } })
      const before = calls.length
      await controller.openCamera()
      return {
        before,
        calls,
        state: controller.cameraState,
        nativeClicks: controller.cameraInputTarget.clicks,
        video: controller.cameraVideoTarget.srcObject === cameraStream,
        submitDisabled: controller.submitButtonTarget.disabled,
        selectorHidden: controller.cameraDeviceFieldTarget.classList.contains('hidden'),
        captureFocused: controller.cameraCaptureButtonTarget.focused || false
      }
    JAVASCRIPT

    expect(result).to eq(
      "before" => 0,
      "calls" => [ { "video" => true, "audio" => false } ],
      "state" => "live",
      "nativeClicks" => 0,
      "video" => true,
      "submitDisabled" => true,
      "selectorHidden" => true,
      "captureFocused" => true
    )
  end

  it "rotates the preview in quarter turns, carries the rotation into capture and resets it on exit" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup(), rotations = [], received = []
      await controller.openCamera()
      for (let index = 0; index < 4; index++) {
        controller.rotateCamera()
        rotations.push([controller.cameraRotation, controller.cameraVideoTarget.style.getPropertyValue('width'), controller.cameraVideoTarget.style.getPropertyValue('height')])
      }
      controller.rotateCamera()
      controller.cameraCapture.capture = async (video, guide, rotation) => { received.push(rotation); return new Blob(['jpeg'], { type: 'image/jpeg' }) }
      await controller.captureCamera()
      return { rotations, received, final: controller.cameraRotation, state: controller.cameraState }
    JAVASCRIPT

    expect(result).to eq(
      "rotations" => [ [ 90, "400px", "600px" ], [ 180, "600px", "400px" ], [ 270, "400px", "600px" ], [ 0, "600px", "400px" ] ],
      "received" => [ 90 ], "final" => 0, "state" => "idle"
    )
  end

  it "does not rotate outside live capture or during upload and resets orientation for another camera" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup(), ignored = []
      for (const state of ['idle', 'requesting', 'capturing', 'error']) {
        controller.cameraState = state
        controller.rotateCamera()
        ignored.push(controller.cameraRotation)
      }
      controller.cameraState = 'idle'
      await controller.openCamera()
      controller.element.setAttribute('aria-busy', 'true')
      controller.rotateCamera()
      ignored.push(controller.cameraRotation)
      controller.element.removeAttribute('aria-busy')
      controller.rotateCamera()
      await controller.startCamera('another-device')
      return { ignored, reset: controller.cameraRotation }
    JAVASCRIPT

    expect(result).to eq("ignored" => [ 0, 0, 0, 0, 0 ], "reset" => 0)
  end

  it "assigns scoped Space to the enabled shutter and Escape to the existing cancellation path" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup(), target = node()
      await controller.openCamera()
      const event = (key) => ({ key, target, preventDefault () { this.prevented = true }, stopPropagation () { this.stopped = true } })
      const space = event(' ')
      controller.handleCameraKeydown(space)
      controller.cameraCaptureButtonTarget.disabled = true
      controller.handleCameraKeydown(event(' '))
      const escape = event('Escape')
      controller.handleCameraKeydown(escape)
      return { shots: controller.cameraCaptureButtonTarget.clicks, space: [space.prevented, space.stopped], escape: [escape.prevented, escape.stopped], state: controller.cameraState, focused: controller.cameraButtonTarget.focused }
    JAVASCRIPT

    expect(result).to eq("shots" => 1, "space" => [ true, true ], "escape" => [ true, true ], "state" => "idle", "focused" => true)
  end

  it "does not steal editing, native button, composition, modifier or repeated keyboard operations" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup(), target = node()
      await controller.openCamera()
      const ignored = [
        { key: 'Enter' }, { key: 'Backspace' }, { key: ' ', repeat: true }, { key: 'Escape', isComposing: true },
        { key: 'Escape', keyCode: 229 }, { key: 'Escape', defaultPrevented: true },
        ...['ctrlKey', 'altKey', 'metaKey', 'shiftKey'].map((modifier) => ({ key: 'Escape', [modifier]: true })),
        { key: ' ', target: { closest: (selector) => selector.startsWith('button,') ? node() : null } },
        { key: 'Escape', target: { closest: () => node() } },
        { key: 'Escape', target: { isContentEditable: true, closest: () => null } }
      ]
      const prevented = []
      for (const values of ignored) controller.handleCameraKeydown({ target, preventDefault () { prevented.push(true) }, stopPropagation () {}, ...values })
      controller.cameraState = 'capturing'
      controller.handleCameraKeydown({ key: ' ', target, preventDefault () {}, stopPropagation () {} })
      return { shots: controller.cameraCaptureButtonTarget.clicks, prevented, state: controller.cameraState }
    JAVASCRIPT

    expect(result).to eq("shots" => 0, "prevented" => [], "state" => "capturing")
  end

  it "keeps native capture for coarse pointers and unavailable browser APIs" do
    result = run_upload_script(<<~JAVASCRIPT)
      const results = []
      for (const capability of ['coarse', 'insecure', 'missing', 'missingPointer']) {
        const controller = setup()
        if (capability === 'coarse') window.matchMedia = () => ({ matches: false })
        if (capability === 'insecure') window.isSecureContext = false
        if (capability === 'missing') navigator.mediaDevices = undefined
        if (capability === 'missingPointer') window.matchMedia = undefined
        await controller.openCamera()
        results.push([controller.cameraInputTarget.clicks, controller.cameraState])
      }
      return results
    JAVASCRIPT

    expect(result).to eq(Array.new(4) { [ 1, "idle" ] })
  end

  it "ignores repeated start clicks and preserves the previous selection after cancelling unresolved permission" do
    result = run_upload_script(<<~JAVASCRIPT)
      const pending = deferred(), late = stream()
      let calls = 0
      const controller = setup({ getUserMedia () { calls += 1; return pending.promise } })
      const prior = selectPrior(controller)
      const opening = controller.openCamera()
      await controller.openCamera()
      const disabled = controller.submitButtonTarget.disabled
      controller.cancelCamera()
      pending.resolve(late)
      await opening
      return {
        calls,
        disabled,
        state: controller.cameraState,
        stopped: late.track.stopped,
        selected: controller.selectedFiles[0] === prior,
        input: controller.cameraInputTarget.files[0] === prior,
        submitDisabled: controller.submitButtonTarget.disabled
      }
    JAVASCRIPT

    expect(result).to eq("calls" => 1, "disabled" => true, "state" => "idle", "stopped" => 1, "selected" => true, "input" => true, "submitDisabled" => false)
  end

  it "renders device labels as text with opaque IDs and switches only a listed device" do
    result = run_upload_script(<<~JAVASCRIPT)
      const calls = [], streams = []
      const controller = setup({
        async getUserMedia ({ video }) { calls.push(video); const next = stream(video.deviceId?.exact || 'private-one'); streams.push(next); return next },
        async enumerateDevices () { return [{ kind: 'videoinput', deviceId: 'private-one', label: '<img src=x>' }, { kind: 'videoinput', deviceId: 'private-two', label: '' }] }
      })
      await controller.openCamera()
      const options = controller.cameraDeviceSelectTarget.children.map((option) => [option.value, option.textContent])
      await controller.switchCamera({ target: { value: 'private-two' } })
      controller.cameraDeviceSelectTarget.value = options[1][0]
      await controller.switchCamera({ target: controller.cameraDeviceSelectTarget })
      return {
        options,
        calls,
        stopped: streams[0].track.stopped,
        current: controller.cameraVideoTarget.srcObject === streams[1],
        selectorHidden: controller.cameraDeviceFieldTarget.classList.contains('hidden')
      }
    JAVASCRIPT

    expect(result).to eq(
      "options" => [ [ "camera-0", "<img src=x>" ], [ "camera-1", "Camera 2" ] ],
      "calls" => [ true, { "deviceId" => { "exact" => "private-two" } } ],
      "stopped" => 1,
      "current" => true,
      "selectorHidden" => false
    )
  end

  it "uses the existing single-file preview after capture and stops all camera tracks" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup()
      await controller.openCamera()
      const active = controller.cameraVideoTarget.srcObject
      await controller.captureCamera()
      const file = controller.cameraInputTarget.files[0]
      return {
        state: controller.cameraState,
        file: [file.name, file.type, file.size],
        selected: controller.selectedFiles[0] === file,
        libraryCount: controller.libraryInputTarget.files.length,
        stopped: active.track.stopped,
        video: controller.cameraVideoTarget.srcObject,
        submitDisabled: controller.submitButtonTarget.disabled
      }
    JAVASCRIPT

    expect(result).to eq("state" => "idle", "file" => [ "receipt-camera.jpg", "image/jpeg", 4 ], "selected" => true, "libraryCount" => 0, "stopped" => 1, "video" => nil, "submitDisabled" => false)
  end

  it "passes the current rendered guide to capture and refuses missing geometry without replacing a selected file" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup(), calls = []
      const prior = selectPrior(controller)
      controller.cameraCapture.capture = async (_video, guide) => { calls.push(guide); return new Blob(['jpeg'], { type: 'image/jpeg' }) }
      await controller.openCamera()
      controller.cameraVideoTarget.videoWidth = 0
      controller.cameraFrameReady()
      const disabled = controller.cameraCaptureButtonTarget.disabled
      await controller.captureCamera()
      const preserved = controller.selectedFiles[0] === prior
      controller.cameraVideoTarget.videoWidth = 640
      await controller.openCamera()
      await controller.captureCamera()
      return { disabled, preserved, calls, selected: controller.selectedFiles[0].name }
    JAVASCRIPT

    expect(result).to eq(
      "disabled" => true, "preserved" => true,
      "calls" => [ { "left" => 200, "top" => 100, "width" => 100, "height" => 150 } ],
      "selected" => "receipt-camera.jpg"
    )
  end

  it "preserves a prior file when permission, playback, capture or file assignment fails" do
    result = run_upload_script(<<~JAVASCRIPT)
      const results = []
      for (const failure of ['permission', 'playback', 'capture', 'assignment', 'quota']) {
        const controller = setup()
        const prior = selectPrior(controller)
        if (failure === 'permission') navigator.mediaDevices.getUserMedia = async () => { throw Object.assign(new Error('private detail'), { name: 'NotAllowedError' }) }
        if (failure === 'playback') controller.cameraVideoTarget.play = async () => { throw new Error('private detail') }
        await controller.openCamera()
        if (failure === 'capture') controller.cameraVideoTarget.videoWidth = 0
        if (failure === 'assignment') controller.cameraInputTarget.assignmentFails = true
        if (failure === 'quota') {
          controller.storageLimitBytesValue = 6
          controller.cameraCapture.capture = async () => new Blob(['new capture'], { type: 'image/jpeg' })
        }
        if (!['permission', 'playback'].includes(failure)) await controller.captureCamera()
        const title = controller.cameraStatusTitleTarget.textContent
        controller.cancelCamera()
        results.push([failure, title, controller.selectedFiles[0] === prior, controller.cameraInputTarget.files[0] === prior, controller.cameraState])
      }
      return results
    JAVASCRIPT

    expect(result).to eq([
      [ "permission", "permission", true, true, "idle" ], [ "playback", "unavailable", true, true, "idle" ],
      [ "capture", "capture", true, true, "idle" ], [ "assignment", "capture", true, true, "idle" ], [ "quota", "capture", true, true, "idle" ]
    ])
  end

  it "discards a capture callback arriving after cancellation" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup(), pending = deferred()
      const prior = selectPrior(controller)
      await controller.openCamera()
      controller.cameraCapture.capture = () => pending.promise
      const capturing = controller.captureCamera()
      controller.cancelCamera()
      pending.resolve(new Blob(['new'], { type: 'image/jpeg' }))
      await capturing
      return { state: controller.cameraState, selected: controller.selectedFiles[0] === prior, input: controller.cameraInputTarget.files[0] === prior }
    JAVASCRIPT

    expect(result).to eq("state" => "idle", "selected" => true, "input" => true)
  end

  it "stops cameras on file selection, drop, submit, service stop, cache, disconnect and hidden pages" do
    result = run_upload_script(<<~JAVASCRIPT)
      const results = []
      for (const action of ['library', 'cameraFile', 'libraryFile', 'drop', 'submit', 'ocr', 'cache', 'disconnect', 'hidden', 'pagehide']) {
        const controller = setup()
        await controller.openCamera()
        const active = controller.cameraVideoTarget.srcObject
        let prevented = false
        const event = { preventDefault () { prevented = true }, dataTransfer: { files: [] } }
        if (action === 'library') controller.openLibrary()
        if (action === 'cameraFile') controller.previewCamera()
        if (action === 'libraryFile') controller.previewLibrary()
        if (action === 'drop') controller.handleDrop(event)
        if (action === 'submit') controller.disableSubmit(event)
        if (action === 'ocr') { controller.ocrAvailableValue = false; controller.ocrAvailableValueChanged() }
        if (action === 'cache') document.dispatchEvent(new Event('turbo:before-cache'))
        if (action === 'disconnect') controller.disconnect()
        if (action === 'hidden') { document.hidden = true; document.dispatchEvent(new Event('visibilitychange')) }
        if (action === 'pagehide') window.dispatchEvent(new Event('pagehide'))
        results.push([action, active.track.stopped, controller.cameraVideoTarget.srcObject, action === 'submit' ? prevented : true])
      }
      return results
    JAVASCRIPT

    expect(result).to eq(%w[library cameraFile libraryFile drop submit ocr cache disconnect hidden pagehide].map { |action| [ action, 1, nil, true ] })
  end

  it "closes an unexpectedly ended stream with a safe error and does not restart automatically" do
    result = run_upload_script(<<~JAVASCRIPT)
      let calls = 0
      const controller = setup({ async getUserMedia () { calls += 1; return stream() }, async enumerateDevices () { return [] } })
      await controller.openCamera()
      const active = controller.cameraVideoTarget.srcObject
      active.track.dispatchEvent(new Event('ended'))
      document.dispatchEvent(new Event('visibilitychange'))
      return { calls, state: controller.cameraState, title: controller.cameraStatusTitleTarget.textContent, stopped: active.track.stopped }
    JAVASCRIPT

    expect(result).to eq("calls" => 1, "state" => "error", "title" => "unavailable", "stopped" => 1)
  end

  it "keeps an upload disabled when camera teardown or file preview runs during a pending submission" do
    result = run_upload_script(<<~JAVASCRIPT)
      const results = []
      for (const action of ['hidden', 'pagehide', 'cache', 'preview']) {
        const controller = setup(), prior = selectPrior(controller)
        const submit = new Event('submit', { cancelable: true })
        controller.disableSubmit(submit)
        controller.element.setAttribute('aria-busy', 'true')
        controller.element.dispatchEvent(new Event('turbo:submit-start'))
        if (action === 'hidden') { document.hidden = true; document.dispatchEvent(new Event('visibilitychange')) }
        if (action === 'pagehide') window.dispatchEvent(new Event('pagehide'))
        if (action === 'cache') document.dispatchEvent(new Event('turbo:before-cache'))
        if (action === 'preview') controller.previewCamera()
        results.push([action, submit.defaultPrevented, controller.submitButtonTarget.disabled, controller.cameraButtonTarget.disabled, controller.selectedFiles[0] === prior])
      }
      return results
    JAVASCRIPT

    expect(result).to eq(%w[hidden pagehide cache preview].map { |action| [ action, false, true, true, true ] })
  end

  it "rejects another submit and camera start while the upload is busy" do
    result = run_upload_script(<<~JAVASCRIPT)
      const results = []
      for (const finePointer of [true, false]) {
        let calls = 0
        const controller = setup({ async getUserMedia () { calls += 1; return stream() }, async enumerateDevices () { return [] } })
        const prior = selectPrior(controller)
        window.matchMedia = () => ({ matches: finePointer })
        controller.element.setAttribute('aria-busy', 'true')
        controller.element.dispatchEvent(new Event('turbo:submit-start'))
        const submit = new Event('submit', { cancelable: true })
        controller.disableSubmit(submit)
        await controller.openCamera()
        results.push([submit.defaultPrevented, calls, controller.cameraInputTarget.clicks, controller.cameraState, controller.selectedFiles[0] === prior])
      }
      return results
    JAVASCRIPT

    expect(result).to eq(Array.new(2) { [ true, 0, 0, "idle", true ] })
  end

  it "restores available controls at submit end while preserving service and file-selection gates" do
    result = run_upload_script(<<~JAVASCRIPT)
      const results = []
      for (const outcome of ['success', 'error', 'unavailable', 'empty']) {
        const controller = setup()
        if (outcome !== 'empty') selectPrior(controller)
        controller.element.setAttribute('aria-busy', 'true')
        controller.element.dispatchEvent(new Event('turbo:submit-start'))
        if (outcome === 'unavailable') { controller.ocrAvailableValue = false; controller.ocrAvailableValueChanged() }
        controller.element.removeAttribute('aria-busy')
        controller.submitButtonTarget.disabled = false
        controller.element.dispatchEvent(new Event('turbo:submit-end'))
        const disabled = [controller.submitButtonTarget.disabled, controller.cameraButtonTarget.disabled]
        const submit = new Event('submit', { cancelable: true })
        if (['success', 'error'].includes(outcome)) controller.disableSubmit(submit)
        results.push([outcome, ...disabled, submit.defaultPrevented, controller.cameraState])
      }
      return results
    JAVASCRIPT

    expect(result).to eq([
      [ "success", false, false, false, "idle" ], [ "error", false, false, false, "idle" ],
      [ "unavailable", true, true, false, "idle" ], [ "empty", true, false, false, "idle" ]
    ])
  end

  it "keeps capture disabled until a frame is ready and hides retry controls during live capture" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup()
      controller.cameraVideoTarget.readyState = 1
      await controller.openCamera()
      const waiting = controller.cameraCaptureButtonTarget.disabled
      controller.cameraVideoTarget.readyState = 2
      controller.cameraFrameReady()
      return {
        waiting,
        ready: !controller.cameraCaptureButtonTarget.disabled,
        retryHidden: controller.cameraRetryTarget.classList.contains('hidden'),
        retryInline: controller.cameraRetryTarget.classList.contains('inline-flex')
      }
    JAVASCRIPT

    expect(result).to eq("waiting" => true, "ready" => true, "retryHidden" => true, "retryInline" => false)
  end

  it "discards streams resolved after service stop or disconnect and never repopulates a closed panel" do
    result = run_upload_script(<<~JAVASCRIPT)
      const results = []
      for (const action of ['ocr', 'disconnect']) {
        const pending = deferred(), late = stream()
        const controller = setup({ getUserMedia: () => pending.promise })
        const opening = controller.openCamera()
        if (action === 'ocr') { controller.ocrAvailableValue = false; controller.ocrAvailableValueChanged() } else controller.disconnect()
        pending.resolve(late)
        await opening
        results.push([controller.cameraState, late.track.stopped, controller.cameraVideoTarget.srcObject, controller.cameraPanelTarget.classList.contains('hidden')])
      }
      return results
    JAVASCRIPT

    expect(result).to eq(Array.new(2) { [ "idle", 1, nil, true ] })
  end

  it "does not adopt an old capture after the same controller disconnects and reconnects" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup(), pending = deferred()
      const prior = selectPrior(controller)
      await controller.openCamera()
      controller.cameraCapture.capture = () => pending.promise
      const capturing = controller.captureCamera()
      controller.disconnect()
      controller.connect()
      await controller.openCamera()
      const currentStream = controller.cameraVideoTarget.srcObject
      pending.resolve(new Blob(['stale capture'], { type: 'image/jpeg' }))
      await capturing
      return { state: controller.cameraState, input: controller.cameraInputTarget.files[0] === prior, selected: controller.selectedFiles[0] === prior, stopped: currentStream.track.stopped }
    JAVASCRIPT

    expect(result).to eq("state" => "live", "input" => true, "selected" => true, "stopped" => 0)
  end

  it "starts the five-second hint timer only after a video frame is ready" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup()
      controller.cameraVideoTarget.readyState = 1
      await controller.openCamera()
      window.advance(6000)
      const waiting = controller.cameraHintTarget.classList.contains('is-dismissed')
      controller.cameraVideoTarget.readyState = 2
      controller.cameraFrameReady()
      window.advance(4999)
      const before = controller.cameraHintTarget.classList.contains('is-dismissed')
      controller.cameraFrameReady()
      window.advance(1)
      return {
        waiting, before,
        dismissed: controller.cameraHintTarget.classList.contains('is-dismissed'),
        inert: controller.cameraHintTarget.hasAttribute('inert'),
        state: controller.cameraState
      }
    JAVASCRIPT

    expect(result).to eq("waiting" => false, "before" => false, "dismissed" => true, "inert" => true, "state" => "live")
  end

  it "defers automatic hint dismissal while focused and resumes after focus leaves" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup(), close = node()
      controller.cameraHintTarget.appendChild(close)
      await controller.openCamera()
      close.focus()
      window.advance(5000)
      const focused = controller.cameraHintTarget.classList.contains('is-dismissed')
      controller.resumeCameraHintDismissal({ relatedTarget: close })
      const within = controller.cameraHintTarget.classList.contains('is-dismissed')
      controller.cameraCaptureButtonTarget.focus()
      controller.resumeCameraHintDismissal({ relatedTarget: controller.cameraCaptureButtonTarget })
      return { focused, within, dismissed: controller.cameraHintTarget.classList.contains('is-dismissed') }
    JAVASCRIPT

    expect(result).to eq("focused" => false, "within" => false, "dismissed" => true)
  end

  it "removes the dismissed hint from keyboard navigation and returns manual-close focus to capture" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup(), close = node()
      controller.cameraHintTarget.appendChild(close)
      await controller.openCamera()
      close.focus()
      controller.dismissCameraHint(new Event('click'))
      return {
        dismissed: controller.cameraHintTarget.classList.contains('is-dismissed'),
        inert: controller.cameraHintTarget.hasAttribute('inert'),
        captureFocused: document.activeElement === controller.cameraCaptureButtonTarget,
        timers: window.timers.size
      }
    JAVASCRIPT

    expect(result).to eq("dismissed" => true, "inert" => true, "captureFocused" => true, "timers" => 0)
  end

  it "clears hint timers across cancellation and rejects callbacks from an earlier camera session" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup()
      await controller.openCamera()
      const stale = [...window.timers.values()].find((timer) => timer.at === 5000).callback
      window.advance(1000)
      controller.cancelCamera()
      const cancelled = window.timers.size
      await controller.openCamera()
      stale()
      window.advance(4999)
      const visible = !controller.cameraHintTarget.classList.contains('is-dismissed')
      window.advance(1)
      const dismissed = controller.cameraHintTarget.classList.contains('is-dismissed')
      controller.disconnect()
      return { cancelled, visible, dismissed, remaining: window.timers.size }
    JAVASCRIPT

    expect(result).to eq("cancelled" => 0, "visible" => true, "dismissed" => true, "remaining" => 0)
  end

  it "keeps a manually dismissed hint closed before video readiness and focuses an available control" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup(), close = node()
      controller.cameraHintTarget.appendChild(close)
      controller.cameraVideoTarget.readyState = 1
      await controller.openCamera()
      close.focus()
      controller.dismissCameraHint(new Event('click'))
      const focused = document.activeElement === controller.cameraCancelTarget
      controller.cameraVideoTarget.readyState = 2
      controller.cameraFrameReady()
      return { focused, timers: window.timers.size, dismissed: controller.cameraHintTarget.classList.contains('is-dismissed') }
    JAVASCRIPT

    expect(result).to eq("focused" => true, "timers" => 0, "dismissed" => true)
  end

  it "keeps upload height responsive across camera states, narrow screens and short viewports" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup(), layout = node(), card = node(), guidance = node(), main = node()
      layout.getBoundingClientRect = () => ({ top: 200 - window.scrollY, height: 900, width: 1200 })
      guidance.getBoundingClientRect = () => ({ height: 900, width: 300 })
      card.getBoundingClientRect = () => ({ height: 700, width: 800 })
      controller.element.closest = (selector) => selector === '[data-receipt-upload-layout]' ? layout : card
      layout.querySelector = () => guidance
      layout.closest = () => main
      const header = node()
      header.getBoundingClientRect = () => ({ height: 64 })
      document.querySelector = () => header
      controller.disconnect()
      controller.connect()
      window.advance(0)
      const property = '--receipt-upload-stage-height'
      const tall = controller.dropzoneTarget.style.getPropertyValue(property)
      await controller.openCamera()
      const live = controller.dropzoneTarget.style.getPropertyValue(property)
      controller.cancelCamera()
      const cancelled = controller.dropzoneTarget.style.getPropertyValue(property)
      window.scrollY = 100
      controller.syncUploadHeight()
      const scrolled = controller.dropzoneTarget.style.getPropertyValue(property)
      window.innerHeight = 900
      controller.syncUploadHeight()
      const stageFits = controller.dropzoneTarget.style.getPropertyValue(property)
      window.innerHeight = 640
      controller.syncUploadHeight()
      const short = controller.dropzoneTarget.style.getPropertyValue(property)
      window.innerHeight = 1200
      window.matchMedia = () => ({ matches: false })
      controller.syncUploadHeight()
      const narrow = controller.dropzoneTarget.style.getPropertyValue(property)
      window.innerHeight = 320
      controller.syncUploadHeight()
      const minimum = controller.dropzoneTarget.style.getPropertyValue(property)
      controller.disconnect()
      return { tall, live, cancelled, scrolled, stageFits, short, narrow, minimum, remaining: window.timers.size }
    JAVASCRIPT

    expect(result).to eq(
      "tall" => "600px", "live" => "600px", "cancelled" => "600px", "scrolled" => "600px",
      "stageFits" => "600px", "short" => "536px", "narrow" => "400px", "minimum" => "320px", "remaining" => 0
    )
  end

  it "coalesces size changes and releases upload observers only on page teardown" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup(), layout = node(), card = node(), guidance = node()
      const property = '--receipt-upload-stage-height'
      let observer, writes = 0
      const setProperty = controller.dropzoneTarget.style.setProperty
      controller.dropzoneTarget.style.setProperty = (name, value) => { writes += 1; setProperty(name, value) }
      controller.dropzoneTarget.getBoundingClientRect = () => ({ height: Number.parseFloat(controller.dropzoneTarget.style.getPropertyValue(property)) || 400 })
      card.getBoundingClientRect = () => ({ height: controller.dropzoneTarget.getBoundingClientRect().height + 300 })
      guidance.getBoundingClientRect = () => ({ height: 900, width: 300 })
      controller.element.closest = (selector) => selector === '[data-receipt-upload-layout]' ? layout : card
      layout.querySelector = () => guidance
      window.ResizeObserver = class {
        constructor (callback) { observer = this; this.callback = callback; this.observed = []; this.disconnected = false }
        observe (element) { this.observed.push(element) }
        disconnect () { this.disconnected = true }
      }
      controller.disconnect()
      controller.connect()
      const before = controller.dropzoneTarget.style.getPropertyValue(property)
      await controller.openCamera()
      observer.callback()
      observer.callback()
      window.dispatchEvent(new Event('resize'))
      window.advance(0)
      const resized = controller.dropzoneTarget.style.getPropertyValue(property)
      const observed = observer.observed.length
      observer.callback()
      controller.cancelCamera()
      window.advance(0)
      const cancelled = controller.dropzoneTarget.style.getPropertyValue(property)
      const active = !observer.disconnected
      document.dispatchEvent(new Event('turbo:before-cache'))
      window.dispatchEvent(new Event('resize'))
      return {
        before, resized, cancelled, active, writes, observed, disconnected: observer.disconnected,
        after: controller.dropzoneTarget.style.getPropertyValue(property), remaining: window.timers.size
      }
    JAVASCRIPT

    expect(result).to eq(
      "before" => "600px", "resized" => "600px", "cancelled" => "600px", "active" => true,
      "writes" => 1, "observed" => 3, "disconnected" => true, "after" => "", "remaining" => 0
    )
  end

  it "fits the camera guide within painted video and the control-free track for every media aspect ratio" do
    result = run_upload_script(<<~JAVASCRIPT)
      const video = { left: 100, top: 50, width: 800, height: 600 }
      const frame = { left: 120, top: 130, width: 760, height: 360 }
      return [[1600, 900], [1200, 900], [900, 1600], [900, 1200], [1000, 1000], [10000, 100], [100, 10000]].map(([videoWidth, videoHeight]) => {
        return cameraGuideBounds({ videoWidth, videoHeight, video, frame, panel: video, inset: 2 })
      })
    JAVASCRIPT

    expect(result).to eq([
      { "left" => 2, "top" => 2, "width" => 756, "height" => 356 },
      { "left" => 2, "top" => 2, "width" => 756, "height" => 356 },
      { "left" => 213.25, "top" => 2, "width" => 333.5, "height" => 356 },
      { "left" => 157, "top" => 2, "width" => 446, "height" => 356 },
      { "left" => 82, "top" => 2, "width" => 596, "height" => 356 },
      { "left" => 2, "top" => 218, "width" => 756, "height" => 4 },
      { "left" => 379, "top" => 2, "width" => 2, "height" => 356 }
    ])
  end

  it "hides a guide with missing media dimensions or no drawable intersection instead of guessing a ratio" do
    result = run_upload_script(<<~JAVASCRIPT)
      const rect = { left: 0, top: 0, width: 800, height: 600 }
      const input = { videoWidth: 1600, videoHeight: 900, video: rect, frame: rect, panel: rect, inset: 2 }
      return [
        { videoWidth: 0 }, { videoHeight: 0 }, { videoWidth: NaN }, { videoHeight: Infinity },
        { videoWidth: -1 }, { inset: NaN }, { frame: { ...rect, top: 700 } },
        { video: { ...rect, width: 0 } }, { panel: { ...rect, width: 3 } }, { frame: { ...rect, left: NaN } }
      ].map((override) => cameraGuideBounds({ ...input, ...override }))
    JAVASCRIPT

    expect(result).to eq(Array.new(10))
  end

  it "resynchronizes the guide for resolution changes and resize without restarting the hint timer" do
    result = run_upload_script(<<~JAVASCRIPT)
      const controller = setup(), layout = node(), card = node(), guidance = node()
      const video = { left: 100, top: 50, width: 800, height: 600 }
      const frame = { left: 120, top: 130, width: 760, height: 360 }
      controller.element.closest = (selector) => selector === '[data-receipt-upload-layout]' ? layout : card
      layout.querySelector = () => guidance
      controller.cameraVideoTarget.getBoundingClientRect = () => video
      controller.cameraPanelTarget.getBoundingClientRect = () => video
      controller.cameraGuideFrameTarget.getBoundingClientRect = () => frame
      controller.setupUploadHeight()
      const bounds = () => ['left', 'top', 'width', 'height'].map((key) => controller.cameraGuideTarget.style.getPropertyValue(key))
      controller.cameraVideoTarget.videoWidth = 1600
      controller.cameraVideoTarget.videoHeight = 900
      await controller.openCamera()
      window.advance(0)
      const landscape = bounds()
      window.advance(1000)
      controller.cameraVideoTarget.videoWidth = 900
      controller.cameraVideoTarget.videoHeight = 1600
      controller.cameraFrameReady()
      window.advance(0)
      const portrait = bounds()
      frame.height = 200
      window.dispatchEvent(new Event('resize'))
      window.advance(0)
      const resized = bounds()
      window.advance(4000)
      const dismissed = controller.cameraHintTarget.classList.contains('is-dismissed')
      controller.cancelCamera()
      const stopped = controller.cameraGuideTarget.classList.contains('invisible')
      controller.cameraVideoTarget.videoWidth = 0
      await controller.openCamera()
      window.advance(0)
      const pending = controller.cameraGuideTarget.classList.contains('invisible')
      controller.cameraVideoTarget.videoWidth = 900
      controller.cameraFrameReady()
      window.advance(0)
      const restarted = !controller.cameraGuideTarget.classList.contains('invisible')
      controller.disconnect()
      return { landscape, portrait, resized, dismissed, stopped, pending, restarted, timers: window.timers.size }
    JAVASCRIPT

    expect(result).to eq(
      "landscape" => %w[2px 2px 756px 356px], "portrait" => %w[213.25px 2px 333.5px 356px],
      "resized" => %w[213.25px 2px 333.5px 196px], "dismissed" => true,
      "stopped" => true, "pending" => true, "restarted" => true, "timers" => 0
    )
  end
end
