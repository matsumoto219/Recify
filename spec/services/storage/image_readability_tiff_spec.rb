require "spec_helper"
require "stringio"
require "image_processing/vips"
require_relative "../../../app/services/storage"
require_relative "../../../app/services/storage/tiff_page_count"
require_relative "../../../app/services/storage/image_readability"

RSpec.describe Storage::ImageReadability do
  let(:image) { Vips::Image.black(120, 160, bands: 3) }

  def readable?(bytes)
    described_class.valid?(io: StringIO.new(bytes), content_type: "image/tiff", max_bytes: 20 * 1024 * 1024, max_dimension: 200)
  end

  [ false, true ].each do |bigtiff|
    it "#{bigtiff ? 'BigTIFF' : 'TIFF'}で全ページを読み取る" do
      bytes = image.join(image, :vertical).tiffsave_buffer(page_height: 160, bigtiff:)

      expect(readable?(bytes)).to be(true)
    end
  end

  it "完全なdirectoryが残っていても最後のページの必須データ欠損を拒否する" do
    bytes = image.join(image, :vertical).tiffsave_buffer(page_height: 160)
    truncated = bytes.byteslice(0, bytes.bytesize - 20)

    expect(Storage::TiffPageCount.call(truncated)).to eq(2)
    expect(readable?(truncated)).to be(false)
  end

  it "循環したdirectoryをdecoderへ渡さず拒否する" do
    bytes = image.tiffsave_buffer
    first_directory = bytes.unpack1("V", offset: 4)
    entries = bytes.unpack1("v", offset: first_directory)
    bytes[first_directory + 2 + entries * 12, 4] = [ first_directory ].pack("V")
    expect(Vips::Image).not_to receive(:new_from_buffer)

    expect(readable?(bytes)).to be(false)
  end
end
