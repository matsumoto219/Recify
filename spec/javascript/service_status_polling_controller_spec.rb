# frozen_string_literal: true

require "base64"
require "json"
require "open3"

RSpec.describe "Service status polling upload controls" do
  let(:source) { File.read(File.expand_path("../../app/javascript/controllers/service_status_polling_controller.js", __dir__)) }

  it "keeps camera and submit controls disabled while a camera or upload is active" do
    encoded = Base64.strict_encode64(source
      .sub("import { Controller } from '@hotwired/stimulus'", "class Controller {}")
      .sub("export default class extends Controller", "class ServiceStatusPollingController extends Controller"))
    script = <<~JAVASCRIPT
      eval(Buffer.from(#{encoded.inspect}, 'base64').toString('utf8') + '\\nglobalThis.ServiceStatusPollingController = ServiceStatusPollingController')
      let busy = null
      const root = { dataset: { receiptUploadCameraActive: 'true' }, getAttribute: () => busy, querySelectorAll: () => [{ files: ['previous-file'] }] }
      const control = (camera) => ({ disabled: true, closest: () => root, matches: () => camera })
      const camera = control(true), library = control(false), submit = control(false)
      const controller = Object.assign(new ServiceStatusPollingController(), { uploadRootTargets: [root], uploadControlTargets: [camera, library], uploadSubmitTargets: [submit] })
      const states = []
      controller.updateUploadAvailability(true)
      states.push([camera.disabled, library.disabled, submit.disabled])
      root.dataset.receiptUploadCameraActive = 'false'
      controller.updateUploadAvailability(true)
      states.push([camera.disabled, library.disabled, submit.disabled])
      busy = 'true'
      controller.updateUploadAvailability(true)
      states.push([camera.disabled, library.disabled, submit.disabled])
      busy = null
      controller.updateUploadAvailability(true)
      states.push([camera.disabled, library.disabled, submit.disabled])
      controller.updateUploadAvailability(false)
      states.push([camera.disabled, library.disabled, submit.disabled])
      process.stdout.write(JSON.stringify(states))
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script)
    raise stderr unless status.success?

    expect(JSON.parse(stdout)).to eq([ [ true, false, true ], [ false, false, false ], [ true, false, true ], [ false, false, false ], [ true, true, true ] ])
  end
end
