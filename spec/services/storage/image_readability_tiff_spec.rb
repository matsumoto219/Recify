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

  %w[classic_tiff_little classic_tiff_big big_tiff_little big_tiff_big].each do |variant|
    it "#{variant}のendianとoffset幅を保ったまま読み取る" do
      bytes = File.binread(File.expand_path("../../fixtures/files/#{variant}.tiff", __dir__))

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
    expect(Vips::Image).not_to receive(:new_from_source)

    expect(readable?(bytes)).to be(false)
  end

  it "各ページは後続directoryのない匿名fileから読み、全chain再走査とbuffer複製をしない" do
    bytes = image.join(image, :vertical).tiffsave_buffer(page_height: 160).freeze
    original = bytes.dup
    decoded_pages = 0
    expect(Vips::Image).not_to receive(:new_from_buffer)
    allow(Vips::Source).to receive(:new_from_descriptor).and_wrap_original do |method, descriptor|
      file = IO.for_fd(descriptor, autoclose: false)
      expect(file.pos).to eq(0)
      expect(Storage::TiffPageCount.call(file.read)).to eq(1)
      file.rewind
      decoded_pages += 1
      method.call(descriptor)
    end

    aggregate_failures do
      expect(readable?(bytes)).to be(true)
      expect(decoded_pages).to eq(2)
      expect(bytes).to eq(original)
    end
  end

  it "pageを切り替える前に各pageの異なるpixelを最後まで読み取る" do
    bytes = image.join(image + 73, :vertical).tiffsave_buffer(page_height: 160)
    averages = []
    allow(Vips::Image).to receive(:new_from_source).and_wrap_original do |method, *args, **options|
      page = method.call(*args, **options)
      allow(page).to receive(:avg).and_wrap_original do |read|
        read.call.tap { |value| averages << value }
      end
      page
    end

    expect(readable?(bytes)).to be(true)
    expect(averages).to eq([ 0, 73 ])
  end
end
