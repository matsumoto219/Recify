require "spec_helper"
require "base64"
require "json"
require_relative "../../../app/services/storage"
require_relative "../../../app/services/storage/heif_image_info"

RSpec.describe Storage::HeifImageInfo do
  let(:variants) { JSON.parse(File.read(File.expand_path("../../fixtures/files/heif_image_variants.json", __dir__))) }

  def bytes(name)
    Base64.strict_decode64(variants.fetch(name))
  end

  it "heixの実bytesからHEVC形式と主画像寸法を返す" do
    expect(described_class.extract(binary: bytes("heix_10"))).to eq(content_type: "image/heic", width: 120, height: 160)
  end

  it "AVIFをHEICとして扱わない" do
    expect(described_class.extract(binary: bytes("avif"))).to be_nil
  end

  it "QuickTime形式の本文をHEIF decoderへ渡さない" do
    binary = [ 20 ].pack("N") + "ftypqt  " + "\0" * 8
    expect(Vips::Image).not_to receive(:new_from_buffer)

    expect(described_class.extract(binary:)).to be_nil
  end

  it "画像でない本文と空の本文を受け付けない" do
    expect(described_class.extract(binary: "not an image")).to be_nil
    expect(described_class.extract(binary: "")).to be_nil
    expect(described_class.extract(binary: nil)).to be_nil
  end

  it "主画像情報を欠く不完全なcontainerを受け付けない" do
    expect(described_class.extract(binary: bytes("heix_10").byteslice(0, 100))).to be_nil
  end

  it "形式や寸法を調べるだけではpixelを展開しない" do
    allow(Vips::Image).to receive(:new_from_buffer).and_wrap_original do |method, *args, **options|
      image = method.call(*args, **options)
      expect(image).not_to receive(:avg)
      expect(image).not_to receive(:write_to_memory)
      image
    end

    expect(described_class.extract(binary: bytes("grid_2x2_small_tiles"))).to eq(content_type: "image/heic", width: 128, height: 128)
  end

  it "decoderの例外本文を返さない" do
    allow(Vips::Image).to receive(:new_from_buffer).and_raise(Vips::Error, "private source")

    expect(described_class.extract(binary: bytes("heix_10"))).to be_nil
  end
end
