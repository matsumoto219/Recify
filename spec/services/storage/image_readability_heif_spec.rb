require "spec_helper"
require "base64"
require "json"
require "stringio"
require_relative "../../../app/services/storage"
require_relative "../../../app/services/storage/image_readability"

RSpec.describe Storage::ImageReadability do
  let(:variants) { JSON.parse(File.read(File.expand_path("../../fixtures/files/heif_image_variants.json", __dir__))) }

  def validation_error(name, max_dimension: 10_000)
    io = StringIO.new(Base64.strict_decode64(variants.fetch(name)))
    described_class.validation_error(io:, content_type: "image/heic", max_bytes: 20 * 1024 * 1024, max_dimension:)
  end

  %w[primary_second mixed_depth_8_10_mif1 mixed_depth_10_8_mif1].each do |name|
    it "#{name}の各画像をそれぞれ読み取る" do
      expect(validation_error(name)).to be_nil
    end
  end

  it "主画像以外も合算した総画素数の上限を維持する" do
    expect(validation_error("primary_second", max_dimension: 250)).to eq(:image_pixel_limit_exceeded)
    expect(validation_error("primary_second", max_dimension: 260)).to be_nil
  end

  it "主画像とthumbnailを別の商品画像として重複計上しない" do
    expect(validation_error("thumbnail_before_primary", max_dimension: 200)).to be_nil
  end

  it "gridをtileの寸法ではなく組立後の主画像寸法で制限する" do
    expect(validation_error("grid_2x2_large_tiles", max_dimension: 255)).to eq(:image_pixel_limit_exceeded)
    expect(validation_error("grid_2x2_large_tiles", max_dimension: 256)).to be_nil
  end

  it "HEIF decoderが読めてもAVIFは許可しない" do
    expect(validation_error("avif")).to eq(:invalid_content_type)
  end

  it "HEVC主画像を持つHEIFは可読な別codecの副画像を含んでも受け付ける" do
    expect(validation_error("mixed_codec_hevc_av1")).to be_nil
  end
end
