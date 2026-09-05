require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "レシートのPCカメラ撮影", type: :system do
  after do |example|
    if example.metadata[:mobile] || example.metadata[:viewport_override]
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: []) if example.metadata[:reduced_motion]
  end

  def visit_camera_upload(user)
    ENV["RECEIPT_OCR_ENABLED"] = "true"
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
    visit new_upload_receipts_path
    wait_for_stimulus_controller("receipt-upload")
  end

  def install_synthetic_camera(mode: "live", devices: 1)
    page.execute_script(<<~JAVASCRIPT, mode, devices)
      const mode = arguments[0], deviceCount = arguments[1]
      const state = { calls: [], streams: [], canvases: [], resolve: null }
      const createStream = () => {
        const canvas = document.createElement('canvas')
        canvas.width = 640
        canvas.height = 480
        const context = canvas.getContext('2d')
        context.fillStyle = '#ffffff'
        context.fillRect(0, 0, canvas.width, canvas.height)
        context.fillStyle = '#222222'
        context.fillRect(100, 100, 200, 20)
        const stream = canvas.captureStream(10)
        state.streams.push(stream)
        state.canvases.push(canvas)
        return stream
      }
      state.resize = (width, height) => {
        const canvas = state.canvases.at(-1)
        canvas.width = width
        canvas.height = height
        const context = canvas.getContext('2d')
        context.fillStyle = '#ffffff'
        context.fillRect(0, 0, width, height)
        state.streams.at(-1).getVideoTracks()[0].requestFrame()
      }
      Object.defineProperty(navigator.mediaDevices, 'getUserMedia', { configurable: true, value: async (constraints) => {
        state.calls.push(constraints)
        if (mode === 'permission') throw new DOMException('Synthetic denied camera', 'NotAllowedError')
        if (mode === 'pending') return new Promise((resolve) => { state.resolve = () => resolve(createStream()) })
        return createStream()
      } })
      Object.defineProperty(navigator.mediaDevices, 'enumerateDevices', { configurable: true, value: async () => {
        return Array.from({ length: deviceCount }, (_, index) => ({ kind: 'videoinput', deviceId: `synthetic-private-device-${index}`, label: index === 0 ? 'Synthetic Camera' : '' }))
      } })
      window.receiptCameraTest = state
    JAVASCRIPT
  end

  def start_camera
    click_button I18n.t("receipts.new_upload.buttons.camera")
    expect(page).to have_css("[data-receipt-upload-target='cameraLive']:not(.hidden)")
    expect(page).to have_button(I18n.t("receipts.new_upload.camera.capture"), disabled: false)
    expect(page).to have_css("svg.receipt-camera-guide:not(.invisible)")
    expect(page).not_to have_button(I18n.t("receipts.new_upload.camera.retry"))
  end

  def resize_synthetic_camera(width, height)
    page.execute_script("window.receiptCameraTest.resize(arguments[0], arguments[1])", width, height)
    expect(page).to have_css("[data-receipt-upload-target=cameraVideo]") do |video|
      page.evaluate_script("[arguments[0].videoWidth, arguments[0].videoHeight]", video) == [ width, height ]
    end
    page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[arguments.length - 1]
      requestAnimationFrame(() => requestAnimationFrame(() => done(true)))
    JAVASCRIPT
  end

  def camera_geometry
    page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const rect = (selector) => {
          const box = document.querySelector(selector).getBoundingClientRect()
          return { x: box.x, y: box.y, width: box.width, height: box.height, bottom: box.bottom, right: box.right }
        }
        return {
          guide: rect('[data-camera-guide]'),
          frame: rect('[data-camera-guide-frame]'),
          hint: rect('[data-receipt-upload-target=cameraHint]'),
          capture: rect('[data-receipt-upload-target=cameraCaptureButton]'),
          cancel: rect('[data-receipt-upload-target=cameraCancel]'),
          toolbar: rect('[data-camera-toolbar]'),
          actions: rect('[data-camera-actions]'),
          video: rect('[data-receipt-upload-target=cameraVideo]')
        }
      })()
    JAVASCRIPT
  end

  def expect_camera_regions_separated(geometry)
    expect(page).to have_css("[data-camera-guide-frame] > svg.receipt-camera-guide")
    expect(page).to have_css("[data-camera-guide-frame] > [data-receipt-upload-target=cameraHint]", visible: :all)
    expect(find("svg.receipt-camera-guide")).to match_style(position: "absolute")
    expect(find("[data-receipt-upload-target=cameraHint]", visible: :all)).to match_style(position: "absolute", bottom: "0px")
    rows, panel_gap, action_right_inset = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const live = document.querySelector('[data-receipt-upload-target=cameraLive]')
        const panel = document.querySelector('[data-receipt-upload-target=cameraPanel]')
        const actions = getComputedStyle(document.querySelector('[data-camera-actions]'))
        return [
          getComputedStyle(live).gridTemplateRows.split(' ').length,
          Number.parseFloat(getComputedStyle(panel).rowGap),
          Number.parseFloat(actions.paddingRight) + Number.parseFloat(actions.borderRightWidth)
        ]
      })()
    JAVASCRIPT
    expect(rows).to eq(2)
    frame = find("[data-camera-guide-frame]")
    expect(frame).to match_style(position: "relative", "min-height" => "0px")
    frame_box = page.evaluate_script(<<~JAVASCRIPT, frame)
      (() => {
        const box = arguments[0].getBoundingClientRect()
        return { top: box.top, bottom: box.bottom, width: box.width, height: box.height }
      })()
    JAVASCRIPT
    guide = geometry.fetch("guide")
    expect(guide.fetch("y")).to be >= frame_box.fetch("top")
    expect(guide.fetch("bottom")).to be <= frame_box.fetch("bottom")
    expect(guide.fetch("width")).to be <= frame_box.fetch("width")
    expect(guide.fetch("height")).to be <= frame_box.fetch("height")
    expect(guide.fetch("height")).to be > guide.fetch("width")
    expect(guide.fetch("width") / guide.fetch("height")).to be_within(0.01).of(2.0 / 3)
    expect(guide.fetch("x")).to be > geometry.fetch("video").fetch("x")
    expect(guide.fetch("right")).to be < geometry.fetch("video").fetch("right")
    expect(guide.fetch("y")).to be >= geometry.fetch("toolbar").fetch("bottom")
    expect(guide.fetch("bottom")).to be <= geometry.fetch("actions").fetch("y")
    expect(geometry.fetch("actions").fetch("y") - frame_box.fetch("bottom")).to be_within(0.1).of(panel_gap)
    expect(geometry.fetch("hint").fetch("y")).to be >= frame_box.fetch("top")
    expect(geometry.fetch("hint").fetch("bottom")).to be_within(0.1).of(frame_box.fetch("bottom"))
    expect(geometry.fetch("hint").fetch("bottom")).to be <= geometry.fetch("actions").fetch("y")
    expect(geometry.fetch("video").fetch("y")).to be <= geometry.fetch("hint").fetch("y")
    expect(geometry.fetch("video").fetch("bottom")).to be >= geometry.fetch("hint").fetch("bottom")
    video_width, video_height = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const video = document.querySelector('[data-receipt-upload-target=cameraVideo]')
        return [video.videoWidth, video.videoHeight]
      })()
    JAVASCRIPT
    video = geometry.fetch("video")
    capture = geometry.fetch("capture")
    cancel = geometry.fetch("cancel")
    expect(capture.fetch("x") + capture.fetch("width").fdiv(2)).to be_within(0.1).of(video.fetch("x") + video.fetch("width").fdiv(2))
    expect(capture.fetch("right")).to be <= cancel.fetch("x")
    expect(cancel.fetch("right")).to be < geometry.fetch("actions").fetch("right")
    expect(geometry.fetch("actions").fetch("right") - cancel.fetch("right")).to be_within(0.1).of(action_right_inset)
    expect(cancel.fetch("width")).to be >= 44
    expect(cancel.fetch("bottom")).to be <= geometry.fetch("actions").fetch("bottom")
    scale = [ video.fetch("width").fdiv(video_width), video.fetch("height").fdiv(video_height) ].min
    painted_left = video.fetch("x") + (video.fetch("width") - video_width * scale) / 2
    painted_top = video.fetch("y") + (video.fetch("height") - video_height * scale) / 2
    strokes = page.evaluate_script(<<~JAVASCRIPT)
      ['.receipt-camera-guide-outline', '[data-camera-guide]'].map((selector) => {
        const element = document.querySelector(selector)
        if (!element) return null
        const style = getComputedStyle(element)
        return { color: style.stroke, width: Number.parseFloat(style.strokeWidth) }
      })
    JAVASCRIPT
    expect(strokes.first).to be_present
    expect(strokes.first.fetch("color")).not_to eq(strokes.last.fetch("color"))
    expect(strokes.first.fetch("width")).to be > strokes.last.fetch("width")
    stroke_margin = strokes.first.fetch("width") / 2
    expect(guide.fetch("x") - stroke_margin).to be >= painted_left
    expect(guide.fetch("right") + stroke_margin).to be <= painted_left + video_width * scale
    expect(guide.fetch("y") - stroke_margin).to be >= painted_top
    expect(guide.fetch("bottom") + stroke_margin).to be <= painted_top + video_height * scale
  end

  it "カメラのJPEGを単一画像upload経路へ渡す" do
    user = create_system_test_user
    visit_camera_upload(user)
    install_synthetic_camera
    start_camera

    expect(page).to have_button(I18n.t("receipts.new_upload.buttons.upload"), disabled: true)
    expect(page).not_to have_css("[data-receipt-upload-target='cameraDeviceField']:not(.hidden)")
    click_button I18n.t("receipts.new_upload.camera.capture")
    expect(page).to have_css("[data-receipt-upload-target='previewWrapper']:not(.hidden)")
    expect(page).not_to have_css("[data-receipt-upload-target='cameraPanel']:not(.hidden)")
    expect(page.evaluate_script("window.receiptCameraTest.streams[0].getTracks().every((track) => track.readyState === 'ended')")).to be(true)
    expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=cameraInput]').files[0].type")).to eq("image/jpeg")

    click_button I18n.t("receipts.new_upload.buttons.upload")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
    receipt = user.receipts.order(:id).last
    expect(receipt).to have_attributes(status: "processing")
    expect(receipt.image).to be_attached
    expect(receipt.image.blob.content_type).to eq("image/jpeg")
    expect(receipt.receipt_analysis_runs.sole).to have_attributes(source: "upload", status: "queued")
    expect_browser_console_clean
  end

  it "権限拒否後も選択済み画像を保持し、キャンセルして戻れる" do
    visit_camera_upload(create_system_test_user)
    find("[data-receipt-upload-target='cameraInput']", visible: :all).attach_file(Rails.root.join("spec/fixtures/files/receipt_sample.jpg"))
    install_synthetic_camera(mode: "permission")
    click_button I18n.t("receipts.new_upload.buttons.camera")

    expect(page).to have_text(I18n.t("receipts.new_upload.camera.messages.permission.title"))
    click_button I18n.t("receipts.new_upload.camera.cancel")
    expect(page).to have_css("[data-receipt-upload-target='previewWrapper']:not(.hidden)")
    expect(page).to have_button(I18n.t("receipts.new_upload.buttons.upload"), disabled: false)
    expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=cameraInput]').files[0].name")).to eq("receipt_sample.jpg")
    expect_browser_console_clean
  end

  it "送信中の画面非表示や状態更新でも再送信を拒否し、通信終了後は再試行できる",
    allowed_browser_console_failures: [ /TypeError: Synthetic upload failure/ ] do
    user = create_system_test_user
    visit_camera_upload(user)
    find("[data-receipt-upload-target='cameraInput']", visible: :all).attach_file(Rails.root.join("spec/fixtures/files/receipt_sample.jpg"))
    install_synthetic_camera
    page.execute_script(<<~JAVASCRIPT)
      const form = document.querySelector('[data-controller=receipt-upload]')
      const originalFetch = window.fetch
      const state = { calls: 0, ended: 0, errors: 0, pending: [] }
      window.fetch = (input, options = {}) => {
        const url = new URL(input instanceof Request ? input.url : input, window.location.href)
        const method = options.method || (input instanceof Request ? input.method : 'GET')
        if (url.href !== form.action || method.toUpperCase() !== 'POST') return originalFetch(input, options)
        state.calls += 1
        return new Promise((resolve, reject) => state.pending.push({ resolve, reject }))
      }
      form.addEventListener('turbo:submit-end', () => { state.ended += 1 })
      form.addEventListener('turbo:fetch-request-error', () => { state.errors += 1 })
      window.receiptUploadTest = state
    JAVASCRIPT

    click_button I18n.t("receipts.new_upload.buttons.upload")
    expect(page).to have_css("form[data-controller=receipt-upload][aria-busy=true]")
    expect(page.evaluate_script("window.receiptUploadTest.calls")).to eq(1)
    page.execute_script(<<~JAVASCRIPT)
      Object.defineProperty(document, 'hidden', { configurable: true, value: true })
      document.dispatchEvent(new Event('visibilitychange'))
      delete document.hidden
      document.dispatchEvent(new Event('visibilitychange'))
    JAVASCRIPT
    expect(page).to have_css("button[data-receipt-upload-target=submitButton]:disabled")
    page.execute_script("window.Stimulus.controllers.find((controller) => controller.identifier === 'service-status-polling').updateUploadAvailability(true)")
    expect(page).to have_css("button[data-receipt-upload-target=submitButton]:disabled")
    expect(page).to have_button(I18n.t("receipts.new_upload.buttons.camera"), disabled: true)
    prevented = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const form = document.querySelector('[data-controller=receipt-upload]')
        const submit = new SubmitEvent('submit', { bubbles: true, cancelable: true, submitter: form.querySelector('[type=submit]') })
        form.dispatchEvent(submit)
        return submit.defaultPrevented
      })()
    JAVASCRIPT
    expect(prevented).to be(true)
    expect(page.evaluate_script("window.receiptUploadTest.calls")).to eq(1)
    expect(page.evaluate_script("window.receiptCameraTest.calls.length")).to eq(0)

    page.execute_script("window.receiptUploadTest.pending.shift().resolve(new Response('', { status: 422, headers: { 'Content-Type': 'text/vnd.turbo-stream.html' } }))")
    expect(page).not_to have_css("form[data-controller=receipt-upload][aria-busy=true]")
    expect(page).to have_button(I18n.t("receipts.new_upload.buttons.upload"), disabled: false)
    expect(page).to have_button(I18n.t("receipts.new_upload.buttons.camera"), disabled: false)
    expect(page).to have_css("[data-receipt-upload-target='previewWrapper']:not(.hidden)")
    expect(page.evaluate_script("window.receiptUploadTest.ended")).to eq(1)

    click_button I18n.t("receipts.new_upload.buttons.upload")
    expect(page).to have_css("form[data-controller=receipt-upload][aria-busy=true]")
    expect(page.evaluate_script("window.receiptUploadTest.calls")).to eq(2)
    page.execute_script("window.receiptUploadTest.pending.shift().reject(new TypeError('Synthetic upload failure'))")
    expect(page).not_to have_css("form[data-controller=receipt-upload][aria-busy=true]")
    expect(page).to have_button(I18n.t("receipts.new_upload.buttons.upload"), disabled: false)
    expect(page).to have_button(I18n.t("receipts.new_upload.buttons.camera"), disabled: false)
    expect(page.evaluate_script("[window.receiptUploadTest.ended, window.receiptUploadTest.errors]")).to eq([ 2, 1 ])
    start_camera
    click_button I18n.t("receipts.new_upload.camera.cancel")
    expect(page).to have_button(I18n.t("receipts.new_upload.buttons.upload"), disabled: false)
    click_button I18n.t("receipts.new_upload.buttons.upload")
    expect(page).to have_css("form[data-controller=receipt-upload][aria-busy=true]")
    expect(page.evaluate_script("window.receiptUploadTest.calls")).to eq(3)
    page.execute_script("window.receiptUploadTest.pending.shift().resolve(new Response('', { status: 422, headers: { 'Content-Type': 'text/vnd.turbo-stream.html' } }))")
    expect(page).not_to have_css("form[data-controller=receipt-upload][aria-busy=true]")
    expect(page.evaluate_script("[window.receiptUploadTest.ended, window.receiptUploadTest.pending.length]")).to eq([ 3, 0 ])
    expect(user.receipts.count).to eq(0)
    severe_entries = browser_console_entries.select do |entry|
      entry.level == "SEVERE" && !blocked_external_font_entry?(entry)
    end
    expect(severe_entries).not_to be_empty
    expect(severe_entries.map(&:message)).to all(match(/TypeError: Synthetic upload failure/))
  end

  it "複数カメラを切り替え、端末IDをDOMへ露出しない" do
    visit_camera_upload(create_system_test_user)
    install_synthetic_camera(devices: 2)
    start_camera

    expect(page).to have_select(I18n.t("receipts.new_upload.camera.device_label"), options: [ "Synthetic Camera", I18n.t("receipts.new_upload.camera.device_fallback", number: 2) ])
    option_values = all("#receipt-camera-device option").map(&:value)
    expect(option_values).to eq(%w[camera-0 camera-1])
    select I18n.t("receipts.new_upload.camera.device_fallback", number: 2), from: I18n.t("receipts.new_upload.camera.device_label")
    expect(page).to have_button(I18n.t("receipts.new_upload.camera.capture"), disabled: false)
    expect(page.evaluate_script("window.receiptCameraTest.streams[0].getTracks()[0].readyState")).to eq("ended")
    click_button I18n.t("receipts.new_upload.camera.cancel")
    expect(page.evaluate_script("window.receiptCameraTest.streams.every((stream) => stream.getTracks().every((track) => track.readyState === 'ended'))")).to be(true)
    expect_browser_console_clean
  end

  it "権限待ちでキャンセルした後の遅いstreamとTurbo遷移時のstreamを停止する" do
    visit_camera_upload(create_system_test_user)
    install_synthetic_camera(mode: "pending")
    click_button I18n.t("receipts.new_upload.buttons.camera")
    expect(page).to have_text(I18n.t("receipts.new_upload.camera.messages.requesting.title"))
    click_button I18n.t("receipts.new_upload.camera.cancel")
    page.execute_script("window.receiptCameraTest.resolve()")
    expect(page).not_to have_css("[data-receipt-upload-target='cameraPanel']:not(.hidden)")
    expect(page.evaluate_script("window.receiptCameraTest.streams[0].getTracks()[0].readyState")).to eq("ended")

    install_synthetic_camera
    start_camera
    page.execute_script("Turbo.visit(arguments[0])", receipts_path)
    expect(page).to have_current_path(receipts_path, ignore_query: true)
    expect(page.evaluate_script("window.receiptCameraTest.streams[0].getTracks()[0].readyState")).to eq("ended")
    expect_browser_console_clean
  end

  it "390pxのdark表示で操作でき、service polling中も撮影と送信を排他にする", :mobile do
    visit_camera_upload(create_system_test_user)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: false
    )
    page.execute_script("document.documentElement.dataset.theme = 'dark'")
    expect(page.evaluate_script("window.innerWidth")).to eq(390)
    find("[data-receipt-upload-target='cameraInput']", visible: :all).attach_file(Rails.root.join("spec/fixtures/files/receipt_sample.jpg"))
    install_synthetic_camera(devices: 2)
    start_camera
    expect(page.evaluate_script("document.querySelector('#receipt-camera-device').clientWidth")).to be > 150
    expect(page.evaluate_script("document.querySelector('label[for=receipt-camera-device]').getBoundingClientRect().height")).to be < 20
    page.execute_script("document.querySelector('#receipt-camera-device option').textContent = 'Synthetic long camera label '.repeat(10)")
    page.execute_script("window.Stimulus.controllers.find((controller) => controller.identifier === 'service-status-polling').updateUploadAvailability(true)")
    expect(page).to have_button(I18n.t("receipts.new_upload.buttons.upload"), disabled: true)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    find("[data-receipt-upload-target='cameraCaptureButton']").send_keys(:tab, :enter)
    expect(page).not_to have_css("[data-receipt-upload-target='cameraPanel']:not(.hidden)")

    start_camera
    page.execute_script("window.Stimulus.controllers.find((controller) => controller.identifier === 'service-status-polling').updateUploadAvailability(false)")
    expect(page).not_to have_css("[data-receipt-upload-target='cameraPanel']:not(.hidden)")
    expect(page).to have_button(I18n.t("receipts.new_upload.buttons.upload"), disabled: true)
    expect(page.evaluate_script("window.receiptCameraTest.streams.every((stream) => stream.getTracks().every((track) => track.readyState === 'ended'))")).to be(true)
    expect_browser_console_clean
  end

  it "縦幅に余裕があるPCでは左右カードを揃え、案内専用の余白を設けない", screen_size: [ 1440, 1600 ], viewport_override: true do
    visit_camera_upload(create_system_test_user)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 1440,
      height: 1600,
      deviceScaleFactor: 1,
      mobile: false
    )
    expect(page.evaluate_script("[window.innerWidth, window.innerHeight]")).to eq([ 1440, 1600 ])
    idle_height = page.evaluate_script("document.querySelector('[data-receipt-upload-target=dropzone]').getBoundingClientRect().height")
    install_synthetic_camera(devices: 2)
    start_camera
    expect(page).to have_css("[data-camera-guide]")
    expect_camera_regions_separated(camera_geometry)
    heights = page.evaluate_script(<<~JAVASCRIPT)
      ['[data-receipt-upload-card]', '[data-receipt-upload-guidance] > section', '[data-receipt-upload-target=dropzone]']
        .map((selector) => document.querySelector(selector).getBoundingClientRect().height)
    JAVASCRIPT
    expect(heights[0]).to be_within(1).of(heights[1])
    expect(heights[2]).to be >= 400
    expect(heights[2]).to eq(idle_height)
    click_button I18n.t("receipts.new_upload.camera.cancel")
    expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=dropzone]').getBoundingClientRect().height")).to eq(idle_height)
    expect_browser_console_clean
  end

  it "低いPC画面では表示余白に合わせて縮小し、案内を閉じても枠と撮影位置を動かさない", :reduced_motion, screen_size: [ 1440, 640 ], viewport_override: true do
    visit_camera_upload(create_system_test_user)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 1440,
      height: 640,
      deviceScaleFactor: 1,
      mobile: false
    )
    expect(page.evaluate_script("[window.innerWidth, window.innerHeight]")).to eq([ 1440, 640 ])
    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia",
      features: [ { name: "prefers-reduced-motion", value: "reduce" } ]
    )
    install_synthetic_camera(devices: 2)
    start_camera
    expect(page).to have_css("[data-camera-guide]")
    before = camera_geometry
    expect_camera_regions_separated(before)
    expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=dropzone]').getBoundingClientRect().height")).to eq(536)
    close = find_button(I18n.t("receipts.new_upload.camera.close_guide"))
    normal_color = page.evaluate_script("getComputedStyle(document.querySelector('[data-action=\"receipt-upload#dismissCameraHint\"]')).color")
    close.hover
    error_color = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const sample = document.createElement('span')
        sample.style.color = 'var(--text-error)'
        document.body.appendChild(sample)
        const color = getComputedStyle(sample).color
        sample.remove()
        return color
      })()
    JAVASCRIPT
    expect(close).to match_style(color: Selenium::WebDriver::Support::Color.from_string(error_color).rgba)
    expect(error_color).not_to eq(normal_color)
    close.send_keys(:enter)
    expect(page).not_to have_button(I18n.t("receipts.new_upload.camera.close_guide"))
    after = camera_geometry
    expect(after.values_at("guide", "frame", "capture", "video")).to eq(before.values_at("guide", "frame", "capture", "video"))
    expect(page.evaluate_script("document.activeElement.dataset.receiptUploadTarget")).to eq("cameraCaptureButton")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('[data-receipt-upload-target=cameraHint]')).transitionDuration")).to eq("0s")
    click_button I18n.t("receipts.new_upload.camera.cancel")
    expect_browser_console_clean
  end

  it "390pxでも枠を保ち、案内の自動消去後は同じ位置に映像が見える", screen_size: [ 390, 844 ], viewport_override: true do
    visit_camera_upload(create_system_test_user)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: false
    )
    expect(page.evaluate_script("[window.innerWidth, window.innerHeight]")).to eq([ 390, 844 ])
    page.execute_script("document.documentElement.dataset.theme = 'dark'")
    install_synthetic_camera(devices: 2)
    start_camera
    page.execute_script("document.querySelector('#receipt-camera-device option').textContent = 'Synthetic long camera label '.repeat(10)")
    expect(page).to have_css("[data-camera-guide]")
    before = camera_geometry
    expect_camera_regions_separated(before)
    expect(page).to have_css("[data-receipt-upload-target=cameraHint].is-dismissed", visible: :all, wait: 7)
    expect(page).not_to have_button(I18n.t("receipts.new_upload.camera.close_guide"))
    after = camera_geometry
    expect(after.values_at("guide", "frame", "capture", "video")).to eq(before.values_at("guide", "frame", "capture", "video"))
    expect(page.evaluate_script("getComputedStyle(document.querySelector('[data-receipt-upload-target=cameraHint]')).visibility")).to eq("hidden")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    click_button I18n.t("receipts.new_upload.camera.cancel")
    expect_browser_console_clean
  end

  it "極端に低い画面でも未選択・撮影中・終了後の高さを揃え、必要な操作領域だけを保つ", screen_size: [ 390, 320 ], viewport_override: true do
    visit_camera_upload(create_system_test_user)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 320,
      deviceScaleFactor: 1,
      mobile: false
    )
    expect(page.evaluate_script("[window.innerWidth, window.innerHeight]")).to eq([ 390, 320 ])
    expect(page).to have_css("[data-receipt-upload-target=dropzone][style*='320px']")
    idle_height = page.evaluate_script("document.querySelector('[data-receipt-upload-target=dropzone]').getBoundingClientRect().height")
    expect(idle_height).to eq(320)
    install_synthetic_camera(devices: 2)
    start_camera
    expect_camera_regions_separated(camera_geometry)
    expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=dropzone]').getBoundingClientRect().height")).to eq(idle_height)
    click_button I18n.t("receipts.new_upload.camera.cancel")
    expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=dropzone]').getBoundingClientRect().height")).to eq(idle_height)
    expect_browser_console_clean
  end

  it "320pxでも撮影を中央、キャンセルを右端に置き、失敗時は再試行と重ねない", screen_size: [ 320, 640 ], viewport_override: true do
    visit_camera_upload(create_system_test_user)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 320,
      height: 640,
      deviceScaleFactor: 1,
      mobile: false
    )
    expect(page.evaluate_script("[window.innerWidth, window.innerHeight]")).to eq([ 320, 640 ])
    install_synthetic_camera(devices: 2)
    start_camera
    geometry = camera_geometry
    expect_camera_regions_separated(geometry)
    expect(geometry.fetch("cancel").fetch("height")).to be >= 44
    click_button I18n.t("receipts.new_upload.camera.cancel")
    install_synthetic_camera(mode: "permission")
    click_button I18n.t("receipts.new_upload.buttons.camera")
    expect(page).to have_text(I18n.t("receipts.new_upload.camera.messages.permission.title"))
    retry_right, cancel_left = page.evaluate_script(<<~JAVASCRIPT)
      ['cameraRetry', 'cameraCancel'].map((target, index) => {
        const box = document.querySelector(`[data-receipt-upload-target=${target}]`).getBoundingClientRect()
        return index === 0 ? box.right : box.left
      })
    JAVASCRIPT
    expect(retry_right).to be <= cancel_left
    click_button I18n.t("receipts.new_upload.camera.cancel")
    expect_browser_console_clean
  end

  [ [ 1440, 900 ], [ 390, 640 ] ].each do |width, height|
    it "#{width}pxで横長・縦長・正方形の映像変更へ枠を追従させ、余白へはみ出さない", screen_size: [ width, height ], viewport_override: true do
      visit_camera_upload(create_system_test_user)
      page.driver.browser.execute_cdp(
        "Emulation.setDeviceMetricsOverride",
        width: width,
        height: height,
        deviceScaleFactor: 1,
        mobile: false
      )
      expect(page.evaluate_script("[window.innerWidth, window.innerHeight]")).to eq([ width, height ])
      install_synthetic_camera(devices: 2)
      start_camera
      stage_height = page.evaluate_script("document.querySelector('[data-receipt-upload-target=dropzone]').getBoundingClientRect().height")
      [ [ 1600, 900 ], [ 1200, 900 ], [ 900, 1600 ], [ 900, 1200 ], [ 1000, 1000 ] ].each do |video_width, video_height|
        resize_synthetic_camera(video_width, video_height)
        expect_camera_regions_separated(camera_geometry)
        expect(page.evaluate_script("document.querySelector('[data-receipt-upload-target=dropzone]').getBoundingClientRect().height")).to eq(stage_height)
      end
      click_button I18n.t("receipts.new_upload.camera.cancel")
      expect_browser_console_clean
    end
  end

  it "横長・縦長・正方形の映像から枠内だけを元のピクセル数でJPEGへ保存する" do
    visit_camera_upload(create_system_test_user)
    install_synthetic_camera(devices: 2)
    [ [ 1600, 900 ], [ 900, 1600 ], [ 1000, 1000 ] ].each do |video_width, video_height|
      start_camera
      resize_synthetic_camera(video_width, video_height)
      expect_camera_regions_separated(camera_geometry)
      expected = page.evaluate_async_script(<<~JAVASCRIPT)
        const done = arguments[arguments.length - 1]
        const video = document.querySelector('[data-receipt-upload-target=cameraVideo]')
        const videoBox = video.getBoundingClientRect()
        const guide = document.querySelector('[data-camera-guide]').getBoundingClientRect()
        const scale = Math.min(videoBox.width / video.videoWidth, videoBox.height / video.videoHeight)
        const left = videoBox.left + (videoBox.width - video.videoWidth * scale) / 2
        const top = videoBox.top + (videoBox.height - video.videoHeight * scale) / 2
        const x = Math.ceil((guide.left - left) / scale)
        const y = Math.ceil((guide.top - top) / scale)
        const width = Math.floor((guide.right - left) / scale) - x
        const height = Math.floor((guide.bottom - top) / scale) - y
        const canvas = window.receiptCameraTest.canvases.at(-1)
        const context = canvas.getContext('2d')
        video.requestVideoFrameCallback(() => done({ width, height }))
        context.fillStyle = '#ff0000'
        context.fillRect(0, 0, canvas.width, canvas.height)
        context.fillStyle = '#00ff00'
        context.fillRect(x, y, width, height)
        context.fillStyle = '#0000ff'
        context.fillRect(x + Math.floor(width / 2) - 10, y + Math.floor(height / 2) - 10, 20, 20)
        window.receiptCameraTest.streams.at(-1).getVideoTracks()[0].requestFrame()
      JAVASCRIPT
      click_button I18n.t("receipts.new_upload.camera.capture")
      expect(page).to have_css("[data-receipt-upload-target=previewWrapper]:not(.hidden)")
      captured = page.evaluate_async_script(<<~JAVASCRIPT)
        const done = arguments[arguments.length - 1]
        const file = document.querySelector('[data-receipt-upload-target=cameraInput]').files[0]
        createImageBitmap(file).then((image) => {
          const canvas = document.createElement('canvas')
          canvas.width = image.width
          canvas.height = image.height
          const context = canvas.getContext('2d')
          context.drawImage(image, 0, 0)
          const samples = [[8, 8], [image.width - 9, image.height - 9], [Math.floor(image.width / 2), Math.floor(image.height / 2)]]
            .map(([x, y]) => [...context.getImageData(x, y, 1, 1).data].slice(0, 3))
          const result = { width: image.width, height: image.height, type: file.type, samples }
          image.close()
          done(result)
        })
      JAVASCRIPT
      expect(captured.slice("width", "height")).to eq(expected)
      expect(captured.fetch("type")).to eq("image/jpeg")
      expect(captured.fetch("width")).to be < video_width
      [ [ 0, 255, 0 ], [ 0, 255, 0 ], [ 0, 0, 255 ] ].zip(captured.fetch("samples")) do |color, sample|
        color.zip(sample) { |channel, actual| expect(actual).to be_within(15).of(channel) }
      end
    end
    expect_browser_console_clean
  end
end
