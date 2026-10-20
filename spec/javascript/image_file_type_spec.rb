# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "spec_helper"

RSpec.describe "Browser image file type validation" do
  let(:receipt_types) { %w[image/jpeg image/png image/bmp image/tiff image/heif image/heic] }
  let(:preview_types) { %w[image/jpeg image/png image/webp] }

  def allowed_file?(file, types)
    source = File.read(File.expand_path("../../app/javascript/image_file_type.js", __dir__)).gsub(/^export /, "")
    encoded = Base64.strict_encode64(source)
    script = <<~JAVASCRIPT
      eval(Buffer.from(#{encoded.inspect}, 'base64').toString('utf8') + '\\nglobalThis.isAllowedImageFile = isAllowedImageFile')
      process.stdout.write(JSON.stringify(isAllowedImageFile(#{file.to_json}, #{types.to_json})))
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  {
    "image/jpg" => "image/jpeg",
    "image/pjpeg" => "image/jpeg",
    "image/x-png" => "image/png",
    "image/x-bmp" => "image/bmp",
    "image/x-ms-bmp" => "image/bmp",
    "image/x-tiff" => "image/tiff"
  }.each do |type, canonical|
    it "accepts #{type} only for an allowed #{canonical} image" do
      expect(allowed_file?({ type:, name: "selected" }, [ canonical ])).to be(true)
      expect(allowed_file?({ type:, name: "selected.jpg" }, [ "image/webp" ])).to be(false)
    end
  end

  %w[jpg jpeg png bmp tif tiff heif heic].each do |extension|
    it "uses the allowed .#{extension} extension only for an unspecified browser type" do
      aggregate_failures do
        expect(allowed_file?({ type: "", name: "selected.#{extension.upcase}" }, receipt_types)).to be(true)
        expect(allowed_file?({ type: "application/octet-stream", name: "selected.#{extension}" }, receipt_types)).to be(true)
        expect(allowed_file?({ type: "application/pdf", name: "selected.#{extension}" }, receipt_types)).to be(false)
      end
    end
  end

  it "keeps preview and receipt format allowlists independent" do
    aggregate_failures do
      expect(allowed_file?({ type: "", name: "selected.webp" }, preview_types)).to be(true)
      expect(allowed_file?({ type: "image/webp", name: "selected.webp" }, receipt_types)).to be(false)
      %w[bmp tiff heif heic].each do |extension|
        expect(allowed_file?({ type: "", name: "selected.#{extension}" }, preview_types)).to be(false)
      end
    end
  end

  it "accepts canonical MIME independently of the filename and preserves MIME case insensitivity" do
    expect(allowed_file?({ type: "IMAGE/JPEG", name: "selected" }, receipt_types)).to be(true)
  end

  it "does not extend the allowlist to unknown, active-content or video MIME types" do
    aggregate_failures do
      %w[image/gif image/svg+xml image/avif image/unknown image/* text/html video/quicktime application/x-empty].each do |type|
        expect(allowed_file?({ type:, name: "selected.jpg" }, receipt_types)).to be(false)
      end
    end
  end

  it "refuses missing, malformed or unsupported fallback filenames" do
    aggregate_failures do
      [ nil, {}, { type: 1, name: "selected.jpg" } ].each do |file|
        expect(allowed_file?(file, receipt_types)).to be(false)
      end
      [ "", ".jpg", "selected.jpg.exe", "selected.jpg ", "selected.jpg\n", "selected.jpg\0", "path/selected.jpg", "path\\selected.jpg", "selected.pdf", "selected.svg" ].each do |name|
        expect(allowed_file?({ type: "application/octet-stream", name: }, receipt_types)).to be(false)
      end
    end
  end
end
