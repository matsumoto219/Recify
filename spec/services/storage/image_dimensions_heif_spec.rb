require "spec_helper"
require "active_support/all"
require "base64"
require "json"
require "stringio"
require_relative "../../../app/services/storage"
require_relative "../../../app/services/storage/heif_image_info"
require_relative "../../../app/services/storage/image_dimensions"

RSpec.describe Storage::ImageDimensions do
  let(:variants) { JSON.parse(File.read(File.expand_path("../../fixtures/files/heif_image_variants.json", __dir__))) }

  def dimensions_for(name, metadata: {})
    blob = double("blob", content_type: "image/heic", metadata:, persisted?: false)
    change = double("change", attachable: { io: StringIO.new(Base64.strict_decode64(variants.fetch(name))) })

    described_class.extract(blob:, attached_change: change)
  end

  {
    "thumbnail_before_primary" => [ 200, 200 ],
    "grid_2x2_small_tiles" => [ 128, 128 ],
    "grid_2x2_large_tiles" => [ 256, 256 ],
    "primary_second" => [ 200, 220 ],
    "extended_free" => [ 120, 160 ],
    "extended_meta" => [ 120, 160 ],
    "heix_10" => [ 120, 160 ],
    "heix_12" => [ 120, 160 ]
  }.each do |name, (width, height)|
    it "#{name}の主画像の寸法を抽出する" do
      expect(dimensions_for(name)).to eq(width:, height:)
    end
  end

  it "HEICと申告されたAVIFの寸法を返さない" do
    expect(dimensions_for("avif")).to be_nil
  end

  it "既存の保存済み寸法を再解析して変更しない" do
    expect(dimensions_for("primary_second", metadata: { "width" => 300, "height" => 400 })).to eq(width: 300, height: 400)
  end
end
