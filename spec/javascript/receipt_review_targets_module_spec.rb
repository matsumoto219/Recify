# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Receipt review target JavaScript module" do
  def run_module_script(script)
    source = Rails.root.join("app/javascript/receipts/review_targets.js").read.gsub(/^export /, "")
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
      eval(`${source}\n#{script}`)
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  it "parses only same-page review target URLs" do
    result = run_module_script(<<~JAVASCRIPT)
      const location = new URL('https://recify.example/receipts/rcpt_1/edit?tab=items')
      const samePage = reviewTargetUrl('/receipts/rcpt_1/edit?tab=items#receipt-item-42', location.href)
      const otherPath = reviewTargetUrl('/receipts/rcpt_2/edit?tab=items#receipt-item-42', location.href)
      const otherSearch = reviewTargetUrl('/receipts/rcpt_1/edit?tab=summary#receipt-item-42', location.href)
      const otherOrigin = reviewTargetUrl('https://example.net/receipts/rcpt_1/edit?tab=items#receipt-item-42', location.href)

      process.stdout.write(JSON.stringify({
        samePage: samePageReviewTargetUrl(samePage, location),
        otherPath: samePageReviewTargetUrl(otherPath, location),
        otherSearch: samePageReviewTargetUrl(otherSearch, location),
        otherOrigin: samePageReviewTargetUrl(otherOrigin, location),
        malformed: reviewTargetUrl('http://[', location.href)
      }))
    JAVASCRIPT

    expect(result).to eq(
      "samePage" => true,
      "otherPath" => false,
      "otherSearch" => false,
      "otherOrigin" => false,
      "malformed" => nil
    )
  end

  it "round-trips encoded target IDs and preserves malformed hashes safely" do
    result = run_module_script(<<~JAVASCRIPT)
      const targetId = 'receipt-item-商品 42'
      const hash = reviewTargetHash(targetId)

      process.stdout.write(JSON.stringify({
        selector: REVIEW_REASON_TARGET_LINK_SELECTOR,
        hash,
        decoded: reviewTargetIdFromHash(hash),
        empty: reviewTargetIdFromHash(''),
        malformed: reviewTargetIdFromHash('#%E0%A4%A')
      }))
    JAVASCRIPT

    expect(result).to eq(
      "selector" => "a[data-review-reason-target-link]",
      "hash" => "#receipt-item-%E5%95%86%E5%93%81%2042",
      "decoded" => "receipt-item-商品 42",
      "empty" => nil,
      "malformed" => "%E0%A4%A"
    )
  end
end
