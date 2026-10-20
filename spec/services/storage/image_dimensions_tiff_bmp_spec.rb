require "spec_helper"
require "active_support/all"
require "stringio"
require_relative "../../../app/services/storage"
require_relative "../../../app/services/storage/image_dimensions"

RSpec.describe Storage::ImageDimensions do
  def dimensions(bytes, content_type:)
    blob = double("blob", content_type:, metadata: {}, persisted?: false)
    change = double("change", attachable: { io: StringIO.new(bytes) })

    described_class.extract(blob:, attached_change: change)
  end

  def core_bmp_bytes(depth: 24)
    palette = depth == 24 ? "".b : "\0".b * (3 * 2**depth)
    pixels = "\0".b * (((120 * depth + 31) / 32) * 4 * 160)
    offset = 26 + palette.bytesize
    "BM".b + [ offset + pixels.bytesize, 0, 0, offset, 12, 120, 160, 1, depth ].pack("VvvVVvvvv") + palette + pixels
  end

  def tiff_bytes(bigtiff:, big_endian:)
    name = "#{bigtiff ? 'big' : 'classic'}_tiff_#{big_endian ? 'big' : 'little'}.tiff"
    File.binread(File.expand_path("../../fixtures/files/#{name}", __dir__))
  end

  [ 1, 4, 8, 24 ].each do |depth|
    it "#{depth}bit BMP COREHEADERの16-bit寸法を取得する" do
      expect(dimensions(core_bmp_bytes(depth:), content_type: "image/bmp")).to eq(width: 120, height: 160)
    end
  end

  it "BMP INFOHEADERのtop-down画像ではheightの絶対値だけを取る" do
    bytes = "BM".b + [ 54, 0, 0, 54, 40, 120, -160, 1, 24, 0, 0, 0, 0, 0, 0 ].pack("VvvVVl<l<vvVVl<l<VV")

    expect(dimensions(bytes, content_type: "image/bmp")).to eq(width: 120, height: 160)

    bytes[18, 4] = [ -120 ].pack("l<")

    expect(dimensions(bytes, content_type: "image/bmp")).to be_nil
  end

  it "欠損または未知のBMP headerを寸法として解釈しない" do
    bytes = core_bmp_bytes
    unknown = bytes.dup
    unknown[14, 4] = [ 13 ].pack("V")

    expect(dimensions(bytes.byteslice(0, 25), content_type: "image/bmp")).to be_nil
    expect(dimensions(unknown, content_type: "image/bmp")).to be_nil
  end

  [ false, true ].product([ false, true ]).each do |bigtiff, big_endian|
    it "#{bigtiff ? 'BigTIFF' : 'TIFF'}の#{big_endian ? 'big' : 'little'} endian寸法を取得する" do
      bytes = tiff_bytes(bigtiff:, big_endian:)

      expect(dimensions(bytes, content_type: "image/tiff")).to eq(width: 120, height: 160)
    end
  end

  it "BigTIFFの巨大directory数・offsetを本文境界で拒否する" do
    bytes = tiff_bytes(bigtiff: true, big_endian: false)
    directory = bytes.unpack1("Q<", offset: 8)
    bytes[directory, 8] = [ (2**64) - 1 ].pack("Q<")

    expect(dimensions(bytes, content_type: "image/tiff")).to be_nil

    bytes[8, 8] = [ (2**64) - 1 ].pack("Q<")

    expect(dimensions(bytes, content_type: "image/tiff")).to be_nil
  end

  it "BigTIFFの不正offset幅・予約値を拒否する" do
    bytes = tiff_bytes(bigtiff: true, big_endian: false)
    bytes[4, 2] = [ 4 ].pack("v")

    expect(dimensions(bytes, content_type: "image/tiff")).to be_nil

    bytes[4, 4] = [ 8, 1 ].pack("v2")

    expect(dimensions(bytes, content_type: "image/tiff")).to be_nil
  end
end
