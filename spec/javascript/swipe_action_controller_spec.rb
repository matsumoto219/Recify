# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Swipe action Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/swipe_action_controller.js").read }

  def run_controller_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class SwipeActionController extends Controller')

      eval(`${source}\nglobalThis.SwipeActionController = SwipeActionController`)
      #{script}
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "does not capture a pointer that starts on a summary or its child" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(SwipeActionController.prototype)
      let captureCount = 0
      Object.assign(controller, {
        mobileMediaQuery: { matches: true },
        foregroundTarget: {
          setPointerCapture: () => { captureCount += 1 }
        },
        dragging: false,
        open: false,
        setTransition: () => {}
      })
      const summary = {}
      const child = {
        closest: (selector) => selector.includes('summary') ? summary : null
      }

      controller.start({
        target: child,
        pointerType: 'touch',
        button: 0,
        pointerId: 7,
        clientX: 100,
        clientY: 50
      })

      process.stdout.write(JSON.stringify({ captureCount, dragging: controller.dragging }))
    JAVASCRIPT

    expect(result).to eq("captureCount" => 0, "dragging" => false)
  end

  it "keeps swipe capture for a non-interactive part of the mobile row" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(SwipeActionController.prototype)
      let captureCount = 0
      Object.assign(controller, {
        mobileMediaQuery: { matches: true },
        foregroundTarget: {
          setPointerCapture: () => { captureCount += 1 }
        },
        dragging: false,
        open: false,
        currentX: 0,
        setTransition: () => {}
      })
      const rowBackground = { closest: () => null }

      controller.start({
        target: rowBackground,
        pointerType: 'touch',
        button: 0,
        pointerId: 9,
        clientX: 100,
        clientY: 50
      })

      process.stdout.write(JSON.stringify({
        captureCount,
        dragging: controller.dragging,
        pointerId: controller.pointerId
      }))
    JAVASCRIPT

    expect(result).to eq("captureCount" => 1, "dragging" => true, "pointerId" => 9)
  end
end
