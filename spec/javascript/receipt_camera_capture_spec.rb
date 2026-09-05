# frozen_string_literal: true

require "base64"
require "json"
require "open3"

RSpec.describe "Receipt camera capture" do
  let(:source) { File.read(File.expand_path("../../app/javascript/receipts/camera_capture.js", __dir__)) }

  def run_camera_script(script)
    encoded = Base64.strict_encode64(source.gsub(/^export /, ""))
    harness = <<~JAVASCRIPT
      eval(Buffer.from(#{encoded.inspect}, 'base64').toString('utf8') + '\\nglobalThis.CameraCapture = CameraCapture; globalThis.supportsInlineCamera = supportsInlineCamera')
      function stream () {
        const track = { readyState: 'live', stopped: 0, stop () { this.stopped += 1; this.readyState = 'ended' } }
        return { track, getTracks: () => [track], getVideoTracks: () => [track] }
      }
      function deferred () {
        let resolve, reject
        const promise = new Promise((yes, no) => { resolve = yes; reject = no })
        return { promise, resolve, reject }
      }
      function bounds (left = 0, top = 0, width = 640, height = 480) {
        return { left, top, width, height }
      }
      function videoFrame (videoWidth = 640, videoHeight = 480, rectangle = bounds()) {
        return { videoWidth, videoHeight, readyState: 2, getBoundingClientRect: () => rectangle }
      }
      async function run () { #{script} }
      run().then((result) => process.stdout.write(JSON.stringify(result))).catch((error) => { console.error(error); process.exitCode = 1 })
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "requires a secure context, the camera API and a fine pointer without replacing native mobile capture" do
    result = run_camera_script(<<~JAVASCRIPT)
      const enabled = { secureContext: true, mediaDevices: { getUserMedia () {} }, finePointer: true }
      return [
        supportsInlineCamera(enabled),
        supportsInlineCamera({ ...enabled, secureContext: false }),
        supportsInlineCamera({ ...enabled, mediaDevices: undefined }),
        supportsInlineCamera({ ...enabled, mediaDevices: {} }),
        supportsInlineCamera({ ...enabled, finePointer: false })
      ]
    JAVASCRIPT

    expect(result).to eq([ true, false, false, false, false ])
  end

  it "requests video without audio and stops the previous stream before switching devices" do
    result = run_camera_script(<<~JAVASCRIPT)
      const first = stream(), second = stream(), calls = []
      const camera = new CameraCapture({ mediaDevices: {
        async getUserMedia (constraints) { calls.push({ constraints, stopped: first.track.stopped }); return calls.length === 1 ? first : second }
      } })
      await camera.start()
      await camera.start('private-device-id')
      camera.stop()
      camera.stop()
      return { calls, first: first.track.stopped, second: second.track.stopped }
    JAVASCRIPT

    expect(result).to eq(
      "calls" => [
        { "constraints" => { "video" => true, "audio" => false }, "stopped" => 0 },
        { "constraints" => { "video" => { "deviceId" => { "exact" => "private-device-id" } }, "audio" => false }, "stopped" => 1 }
      ], "first" => 1, "second" => 1
    )
  end

  it "stops a late permission result after cancellation and never enumerates devices before permission" do
    result = run_camera_script(<<~JAVASCRIPT)
      const pending = deferred(), late = stream()
      let enumerated = 0
      const camera = new CameraCapture({ mediaDevices: {
        getUserMedia: () => pending.promise,
        async enumerateDevices () { enumerated += 1; return [] }
      } })
      const devicesBefore = await camera.devices()
      const opening = camera.start()
      camera.stop()
      pending.resolve(late)
      return { opened: await opening, devicesBefore, enumerated, stopped: late.track.stopped }
    JAVASCRIPT

    expect(result).to eq("opened" => nil, "devicesBefore" => [], "enumerated" => 0, "stopped" => 1)
  end

  it "rejects stale switch results while keeping the latest camera alive" do
    result = run_camera_script(<<~JAVASCRIPT)
      const first = deferred(), second = deferred(), oldStream = stream(), currentStream = stream()
      const camera = new CameraCapture({ mediaDevices: { getUserMedia: ({ video }) => video.deviceId.exact === 'first' ? first.promise : second.promise } })
      const oldRequest = camera.start('first'), currentRequest = camera.start('second')
      second.resolve(currentStream)
      const current = await currentRequest
      first.resolve(oldStream)
      const old = await oldRequest
      return { current: current === currentStream, old, oldStopped: oldStream.track.stopped, currentStopped: currentStream.track.stopped }
    JAVASCRIPT

    expect(result).to eq("current" => true, "old" => nil, "oldStopped" => 1, "currentStopped" => 0)
  end

  it "ignores permission errors belonging to a cancelled request" do
    result = run_camera_script(<<~JAVASCRIPT)
      const pending = deferred()
      const camera = new CameraCapture({ mediaDevices: { getUserMedia: () => pending.promise } })
      const opening = camera.start()
      camera.stop()
      pending.reject(Object.assign(new Error('private detail'), { name: 'NotAllowedError' }))
      return { opened: await opening }
    JAVASCRIPT

    expect(result).to eq("opened" => nil)
  end

  it "rejects a stream without live video and stops every returned track" do
    result = run_camera_script(<<~JAVASCRIPT)
      const audio = stream().track
      const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return { getVideoTracks: () => [], getTracks: () => [audio] } } } })
      try { await camera.start() } catch (error) { return { reason: error.reason, stopped: audio.stopped } }
    JAVASCRIPT

    expect(result).to eq("reason" => "unavailable", "stopped" => 1)
  end

  it "returns only video devices after permission and tolerates unavailable enumeration" do
    result = run_camera_script(<<~JAVASCRIPT)
      const camera = new CameraCapture({ mediaDevices: {
        async getUserMedia () { return stream() },
        async enumerateDevices () { return [{ kind: 'audioinput' }, { kind: 'videoinput', deviceId: 'one' }, { kind: 'videoinput', deviceId: 'one' }, { kind: 'videoinput', deviceId: 'two' }] }
      } })
      await camera.start()
      const devices = await camera.devices()
      camera.mediaDevices.enumerateDevices = async () => { throw new Error('private detail') }
      return { devices, unavailable: await camera.devices() }
    JAVASCRIPT

    expect(result).to eq("devices" => [ { "kind" => "videoinput", "deviceId" => "one" }, { "kind" => "videoinput", "deviceId" => "two" } ], "unavailable" => [])
  end

  it "does not expose device or exception details in camera errors" do
    result = run_camera_script(<<~JAVASCRIPT)
      const messages = []
      for (const name of ['NotAllowedError', 'SecurityError', 'NotFoundError', 'NotReadableError', 'OverconstrainedError', 'unexpected']) {
        const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { throw Object.assign(new Error('private device detail'), { name }) } } })
        try { await camera.start() } catch (error) { messages.push([error.reason, error.message]) }
      }
      return messages
    JAVASCRIPT

    expect(result).to eq([ %w[permission permission], %w[permission permission], *Array.new(4) { %w[unavailable unavailable] } ])
  end

  it "crops only the guide inside a contained landscape frame at source resolution and releases its canvas" do
    result = run_camera_script(<<~JAVASCRIPT)
      const calls = [], frame = videoFrame(1920, 1080, bounds(100, 50, 800, 800))
      const canvas = {
        width: 0, height: 0,
        getContext: () => ({ drawImage (...args) { calls.push(['draw', args[0] === frame, ...args.slice(1)]) } }),
        toBlob (callback, type, quality) { calls.push(['blob', type, quality, this.width, this.height]); callback(new Blob(['jpeg'], { type })) }
      }
      const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => canvas })
      await camera.start()
      const blob = await camera.capture(frame, bounds(350, 275, 200, 300))
      return { type: blob.type, size: blob.size, calls, width: canvas.width, height: canvas.height }
    JAVASCRIPT

    expect(result).to eq(
      "type" => "image/jpeg", "size" => 4,
      "calls" => [ [ "draw", true, 600, 120, 480, 720, 0, 0, 480, 720 ], [ "blob", "image/jpeg", 0.95, 480, 720 ] ],
      "width" => 0, "height" => 0
    )
  end

  [
    [ 0, [ 140, 80, 300, 500 ], [] ],
    [ 90, [ 80, 360, 500, 300 ], [ [ "translate", 300, 0 ], [ "rotate", Math::PI / 2 ] ] ],
    [ 180, [ 760, 220, 300, 500 ], [ [ "translate", 300, 500 ], [ "rotate", Math::PI ] ] ],
    [ 270, [ 620, 140, 500, 300 ], [ [ "translate", 0, 500 ], [ "rotate", Math::PI * 1.5 ] ] ]
  ].each do |rotation, source_crop, transforms|
    it "captures a noncentral landscape crop rotated #{rotation} degrees clockwise in one canvas" do
      result = run_camera_script(<<~JAVASCRIPT)
        const calls = [], frame = videoFrame(1200, 800, bounds(-40, 30, 600, 600))
        let canvases = 0
        const canvas = {
          getContext: () => ({
            translate (...args) { calls.push(['translate', ...args]) },
            rotate (...args) { calls.push(['rotate', ...args]) },
            drawImage (...args) { calls.push(['draw', args[0] === frame, ...args.slice(1)]) }
          }),
          toBlob (callback, type, quality) { calls.push(['blob', type, quality, this.width, this.height]); callback(new Blob(['jpeg'], { type })) }
        }
        const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => { canvases += 1; return canvas } })
        await camera.start()
        const blob = await camera.capture(frame, #{rotation % 180 == 0 ? "bounds(30, 170, 150, 250)" : "bounds(130, 70, 150, 250)"}, #{rotation})
        return { type: blob.type, size: blob.size, canvases, calls, width: canvas.width, height: canvas.height }
      JAVASCRIPT

      expect(result).to eq(
        "type" => "image/jpeg", "size" => 4, "canvases" => 1,
        "calls" => [ *transforms, [ "draw", true, *source_crop, 0, 0, *source_crop.last(2) ], [ "blob", "image/jpeg", 0.95, 300, 500 ] ],
        "width" => 0, "height" => 0
      )
    end
  end

  it "maps portrait source crops through every clockwise quarter turn without upscaling" do
    result = run_camera_script(<<~JAVASCRIPT)
      const calls = []
      const canvas = {
        getContext: () => ({ translate () {}, rotate () {}, drawImage (...args) { calls.push(args.slice(1)) } }),
        toBlob (callback) { calls.push([this.width, this.height]); callback(new Blob(['jpeg'], { type: 'image/jpeg' })) }
      }
      const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => canvas })
      await camera.start()
      const frame = videoFrame(800, 1200, bounds(10, 20, 600, 600))
      for (const rotation of [0, 90, 180, 270]) {
        const guide = rotation % 180 === 0 ? bounds(170, 70, 210, 130) : bounds(70, 170, 210, 130)
        await camera.capture(frame, guide, rotation)
      }
      return calls
    JAVASCRIPT

    expect(result).to eq([
      [ 120, 100, 420, 260, 0, 0, 420, 260 ], [ 420, 260 ],
      [ 100, 660, 260, 420, 0, 0, 260, 420 ], [ 420, 260 ],
      [ 260, 840, 420, 260, 0, 0, 420, 260 ], [ 420, 260 ],
      [ 440, 120, 260, 420, 0, 0, 260, 420 ], [ 420, 260 ]
    ])
  end

  it "rounds scrolled fractional guide edges inward before inverting each rotation" do
    result = run_camera_script(<<~JAVASCRIPT)
      const draws = []
      const canvas = {
        getContext: () => ({ translate () {}, rotate () {}, drawImage (...args) { draws.push(args.slice(1)) } }),
        toBlob (callback) { callback(new Blob(['jpeg'], { type: 'image/jpeg' })) }
      }
      const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => canvas })
      await camera.start()
      for (const rotation of [0, 90, 180, 270]) {
        await camera.capture(videoFrame(1000, 1000, bounds(-100, -200, 333, 333)), bounds(-66.5, -159.75, 100.1, 100.9), rotation)
      }
      return draws
    JAVASCRIPT

    expect(result).to eq([
      [ 101, 121, 300, 302, 0, 0, 300, 302 ],
      [ 121, 599, 302, 300, 0, 0, 302, 300 ],
      [ 599, 577, 300, 302, 0, 0, 300, 302 ],
      [ 577, 101, 302, 300, 0, 0, 302, 300 ]
    ])
  end

  it "rejects unsupported rotations before allocating a canvas" do
    result = run_camera_script(<<~JAVASCRIPT)
      let canvases = 0
      const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => { canvases += 1 } })
      await camera.start()
      const rejected = []
      for (const rotation of [null, '0', '90', 45, -90, 360, 90.5, NaN, Infinity, -Infinity, true, false, {}, [], new Number(90)]) {
        try { await camera.capture(videoFrame(), bounds(), rotation) } catch (error) { rejected.push([error.reason, error.message]) }
      }
      return { canvases, rejected }
    JAVASCRIPT

    expect(result).to eq("canvases" => 0, "rejected" => Array.new(15) { %w[capture capture] })
  end

  it "keeps rotated crops inside the source frame and rejects letterboxing and subpixel undersized edges" do
    result = run_camera_script(<<~JAVASCRIPT)
      let canvases = 0
      const draws = [], rejected = []
      const canvas = {
        getContext: () => ({ translate () {}, rotate () {}, drawImage (...args) { draws.push(args.slice(1)) } }),
        toBlob (callback) { callback(new Blob(['jpeg'], { type: 'image/jpeg' })) }
      }
      const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => { canvases += 1; return canvas } })
      await camera.start()
      for (const rotation of [90, 180, 270]) {
        const width = rotation === 180 ? 1200 : 800, height = rotation === 180 ? 800 : 1200
        const frame = videoFrame(1200, 800, bounds(0, 0, width, height))
        await camera.capture(frame, bounds(width - 100, height - 100, 100, 100), rotation)
        for (const guide of [bounds(-0.1, 0, 100, 100), bounds(0, -0.1, 100, 100), bounds(width - 99.9, 0, 100, 100), bounds(0, height - 99.9, 100, 100), bounds(0.5, 0.5, 100, 100)]) {
          try { await camera.capture(frame, guide, rotation) } catch (error) { rejected.push(error.reason) }
        }
        try { await camera.capture(videoFrame(1200, 800, bounds(0, 0, 600, 600)), bounds(0, 0, 100, 100), rotation) } catch (error) { rejected.push(error.reason) }
      }
      return { canvases, draws, rejected }
    JAVASCRIPT

    expect(result).to eq(
      "canvases" => 3,
      "draws" => [ [ 1100, 0, 100, 100, 0, 0, 100, 100 ], [ 0, 0, 100, 100, 0, 0, 100, 100 ], [ 0, 700, 100, 100, 0, 0, 100, 100 ] ],
      "rejected" => Array.new(18, "capture")
    )
  end

  it "clears the rotated crop canvas after transformation, drawing and encoding failures" do
    result = run_camera_script(<<~JAVASCRIPT)
      const rejected = []
      for (const failure of ['context', 'translate', 'rotate', 'draw', 'encode']) {
        const fail = (stage) => { if (failure === stage) throw new Error('private detail') }
        const canvas = {
          getContext () {
            fail('context')
            return { translate () { fail('translate') }, rotate () { fail('rotate') }, drawImage () { fail('draw') } }
          },
          toBlob (callback) { fail('encode'); callback(new Blob(['jpeg'], { type: 'image/jpeg' })) }
        }
        const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => canvas })
        await camera.start()
        try { await camera.capture(videoFrame(1200, 800, bounds(0, 0, 800, 1200)), bounds(100, 200, 300, 500), 90) } catch (error) { rejected.push([error.reason, error.message, canvas.width, canvas.height]) }
      }
      return rejected
    JAVASCRIPT

    expect(result).to eq(Array.new(5) { [ "capture", "capture", 0, 0 ] })
  end

  it "rejects unavailable, undersized and oversized frames before allocating a canvas" do
    result = run_camera_script(<<~JAVASCRIPT)
      let canvases = 0
      const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => { canvases += 1 } })
      await camera.start()
      const rejected = []
      for (const rotation of [0, 90, 180, 270]) {
        for (const [videoWidth, videoHeight, readyState] of [[0, 0, 0], [99, 400, 2], [400, 99, 2], [10001, 100, 2], [100, 10001, 2], [Infinity, 400, 2], [100.5, 400, 2]]) {
          try { await camera.capture({ ...videoFrame(videoWidth, videoHeight), readyState }, bounds(), rotation) } catch (error) { rejected.push(error.reason) }
        }
      }
      return { canvases, rejected }
    JAVASCRIPT

    expect(result).to eq("canvases" => 0, "rejected" => Array.new(28, "capture"))
  end

  it "rejects missing, empty, wrong-format and oversized blobs and drawing failures with bounded errors" do
    result = run_camera_script(<<~JAVASCRIPT)
      const rejected = []
      for (const output of [null, new Blob([], { type: 'image/jpeg' }), new Blob(['x'], { type: 'image/png' }), { type: 'image/jpeg', size: 20 * 1024 * 1024 + 1 }, 'draw-error']) {
        const canvas = {
          getContext: () => ({ drawImage () { if (output === 'draw-error') throw new Error('private detail') } }),
          toBlob (callback) { callback(output) }
        }
        const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => canvas })
        await camera.start()
        try { await camera.capture(videoFrame(), bounds()) } catch (error) { rejected.push([error.reason, error.message, canvas.width, canvas.height]) }
      }
      return rejected
    JAVASCRIPT

    expect(result).to eq(Array.new(5) { [ "capture", "capture", 0, 0 ] })
  end

  it "maps portrait, square and resized letterboxed frames without changing source resolution" do
    result = run_camera_script(<<~JAVASCRIPT)
      const draws = []
      const canvas = {
        getContext: () => ({ drawImage (...args) { draws.push(args.slice(1)) } }),
        toBlob (callback) { callback(new Blob(['jpeg'], { type: 'image/jpeg' })) }
      }
      const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => canvas })
      await camera.start()
      await camera.capture(videoFrame(1080, 1920, bounds(80, 20, 800, 600)), bounds(350, 80, 200, 400))
      await camera.capture(videoFrame(1000, 1000, bounds(50, 100, 600, 400)), bounds(200, 150, 200, 300))
      const frame = videoFrame(1920, 1080, bounds(100, 50, 800, 800))
      await camera.capture(frame, bounds(350, 275, 200, 300))
      frame.getBoundingClientRect = () => bounds(100, 50, 400, 400)
      await camera.capture(frame, bounds(225, 162.5, 100, 150))
      frame.videoWidth = 960
      frame.videoHeight = 540
      await camera.capture(frame, bounds(225, 162.5, 100, 150))
      return draws
    JAVASCRIPT

    expect(result).to eq([
      [ 124, 192, 640, 1280, 0, 0, 640, 1280 ],
      [ 125, 125, 500, 750, 0, 0, 500, 750 ],
      [ 600, 120, 480, 720, 0, 0, 480, 720 ],
      [ 600, 120, 480, 720, 0, 0, 480, 720 ],
      [ 300, 60, 240, 360, 0, 0, 240, 360 ]
    ])
  end

  it "rounds fractional source edges inward and keeps scrolled viewport coordinates" do
    result = run_camera_script(<<~JAVASCRIPT)
      const draws = []
      const canvas = {
        getContext: () => ({ drawImage (...args) { draws.push(args.slice(1)) } }),
        toBlob (callback) { callback(new Blob(['jpeg'], { type: 'image/jpeg' })) }
      }
      const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => canvas })
      await camera.start()
      await camera.capture(videoFrame(1000, 1000, bounds(0, 0, 333, 333)), bounds(33.5, 40.25, 100.1, 100.9))
      await camera.capture(videoFrame(1000, 1000, bounds(-100, -200, 500, 500)), bounds(-50, -150, 100, 150))
      return draws
    JAVASCRIPT

    expect(result).to eq([
      [ 101, 121, 300, 302, 0, 0, 300, 302 ],
      [ 100, 100, 200, 300, 0, 0, 200, 300 ]
    ])
  end

  it "accepts exact minimum and maximum crop dimensions without upscaling" do
    result = run_camera_script(<<~JAVASCRIPT)
      const sizes = []
      const canvas = {
        getContext: () => ({ translate () {}, rotate () {}, drawImage () {} }),
        toBlob (callback) { sizes.push([this.width, this.height]); callback({ type: 'image/jpeg', size: 20 * 1024 * 1024 }) }
      }
      const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => canvas })
      await camera.start()
      for (const rotation of [0, 90, 180, 270]) {
        await camera.capture(videoFrame(100, 100, bounds(0, 0, 500, 500)), bounds(0, 0, 500, 500), rotation)
        await camera.capture(videoFrame(10000, 10000, bounds(0, 0, 500, 500)), bounds(0, 0, 500, 500), rotation)
      }
      return sizes
    JAVASCRIPT

    expect(result).to eq(Array.new(4) { [ [ 100, 100 ], [ 10000, 10000 ] ] }.flatten(1))
  end

  it "rejects missing, malformed, outside and undersized guides without allocating a full-frame fallback" do
    result = run_camera_script(<<~JAVASCRIPT)
      let canvases = 0
      const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => { canvases += 1 } })
      await camera.start()
      const rejected = []
      const guides = [
        undefined, null, {}, bounds(0, 0, 0, 100), bounds(0, 0, 100, -1), bounds(NaN, 0, 100, 100),
        bounds(0, Infinity, 100, 100), bounds(0, 0, Infinity, 100), bounds(0, 0, 100, NaN),
        bounds(-0.1, 0, 100, 100), bounds(0, -0.1, 100, 100), bounds(540.1, 0, 100, 100),
        bounds(0, 380.1, 100, 100), bounds(0, 0, 99, 100), bounds(0, 0, 100, 99),
        bounds(0.5, 0.5, 100, 100), bounds('0', 0, 100, 100)
      ]
      for (const guide of guides) {
        try { await camera.capture(videoFrame(), guide) } catch (error) { rejected.push([error.reason, error.message]) }
      }
      try {
        await camera.capture(videoFrame(1920, 1080, bounds(100, 50, 800, 800)), bounds(350, 200, 200, 300))
      } catch (error) { rejected.push([error.reason, error.message]) }
      return { canvases, rejected }
    JAVASCRIPT

    expect(result).to eq("canvases" => 0, "rejected" => Array.new(18) { %w[capture capture] })
  end

  it "rejects invalid displayed video geometry and missing metadata with bounded errors" do
    result = run_camera_script(<<~JAVASCRIPT)
      let canvases = 0
      const camera = new CameraCapture({ mediaDevices: { async getUserMedia () { return stream() } }, createCanvas: () => { canvases += 1 } })
      await camera.start()
      const rejected = []
      const frames = [
        null, videoFrame(0, 0), videoFrame(NaN, 480),
        { ...videoFrame(), readyState: 1 }, { ...videoFrame(), readyState: NaN }, { ...videoFrame(), readyState: undefined },
        videoFrame(640, 480, null), videoFrame(640, 480, bounds(0, 0, 0, 480)),
        videoFrame(640, 480, bounds(0, 0, 640, -1)), videoFrame(640, 480, bounds(Infinity, 0, 640, 480)),
        videoFrame(640, 480, bounds(0, NaN, 640, 480)), videoFrame(640, 480, bounds(0, 0, NaN, 480)),
        { ...videoFrame(), getBoundingClientRect () { throw new Error('private detail') } }
      ]
      for (const frame of frames) {
        try { await camera.capture(frame, bounds()) } catch (error) { rejected.push([error.reason, error.message]) }
      }
      camera.stop()
      try { await camera.capture(videoFrame(), bounds()) } catch (error) { rejected.push([error.reason, error.message]) }
      return { canvases, rejected }
    JAVASCRIPT

    expect(result).to eq("canvases" => 0, "rejected" => Array.new(14) { %w[capture capture] })
  end
end
