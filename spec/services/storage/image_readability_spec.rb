require "spec_helper"
require "stringio"
require "image_processing/vips"
require_relative "../../../app/services/storage"
require_relative "../../../app/services/storage/tiff_page_count"
require_relative "../../../app/services/storage/image_readability"

RSpec.describe Storage::ImageReadability do
  let(:max_bytes) { 20 * 1024 * 1024 }
  let(:max_dimension) { 10_000 }
  let(:image) { Vips::Image.black(120, 160, bands: 3) }
  let(:heic_bytes) { File.binread(File.expand_path("../../fixtures/files/readable_image.heic", __dir__)) }

  def readable?(bytes, content_type:, max_bytes: self.max_bytes, max_dimension: self.max_dimension)
    described_class.valid?(io: StringIO.new(bytes), content_type:, max_bytes:, max_dimension:)
  end

  def bmp_bytes
    pixels = "\0".b * (120 * 160 * 3)
    header = "BM".b + [ 54 + pixels.bytesize, 0, 0, 54 ].pack("VvvV")
    information = [ 40, 120, 160, 1, 24, 0, pixels.bytesize, 0, 0, 0, 0 ].pack("Vl<l<vvVVl<l<VV")
    header + information + pixels
  end

  {
    "PNG" => [ ".png", "image/png" ],
    "JPEG" => [ ".jpg", "image/jpeg" ],
    "TIFF" => [ ".tif", "image/tiff" ],
    "WebP" => [ ".webp", "image/webp" ]
  }.each do |format, (extension, content_type)|
    it "#{format}の全pixelが読み取れる画像を受け付ける" do
      expect(readable?(image.write_to_buffer(extension), content_type:)).to be(true)
    end
  end

  it "全体可読性の検証対象外であるBMPをdecoderへ渡さずfalseを返す" do
    expect(Vips::Image).not_to receive(:new_from_buffer)

    expect(readable?(bmp_bytes, content_type: "image/bmp")).to be(false)
  end

  %w[image/heif image/heic].each do |content_type|
    it "#{content_type}の全pixelが読み取れる画像を受け付ける" do
      expect(readable?(heic_bytes, content_type:)).to be(true)
    end
  end

  it "複数ページの各寸法と合計pixel数が上限内なら受け付ける" do
    bytes = image.join(image, :vertical).tiffsave_buffer(page_height: 160)

    expect(readable?(bytes, content_type: "image/tiff", max_dimension: 200)).to be(true)
  end

  it "各ページが上限内でも合計pixel数を超える画像を受け付けない" do
    bytes = image.join(image, :vertical).tiffsave_buffer(page_height: 160)

    expect(readable?(bytes, content_type: "image/tiff", max_dimension: 160)).to be(false)
  end

  it "最後のページが壊れたTIFFを受け付けない" do
    bytes = image.join(image, :vertical).tiffsave_buffer(page_height: 160)

    expect(readable?(bytes.byteslice(0, bytes.bytesize - 20), content_type: "image/tiff")).to be(false)
  end

  it "末尾のpixelデータが欠けたWebPを受け付けない" do
    bytes = image.write_to_buffer(".webp")

    expect(readable?(bytes.byteslice(0, bytes.bytesize - 50), content_type: "image/webp")).to be(false)
  end

  it "不完全なHEIC containerを受け付けない" do
    expect(readable?(heic_bytes.byteslice(0, heic_bytes.bytesize - 100), content_type: "image/heic")).to be(false)
  end

  it "上限を1byte超える部分だけを読み込み、無制限readをしない" do
    io = StringIO.new("x" * 101)
    expect(io).to receive(:read).with(101).and_call_original

    expect(described_class.valid?(io:, content_type: "image/png", max_bytes: 100, max_dimension:)).to be(false)
  end

  it "寸法だけ読めるPNGヘッダーを受け付けない" do
    bytes = image.write_to_buffer(".png").byteslice(0, 33)

    expect(readable?(bytes, content_type: "image/png")).to be(false)
  end

  it "末尾のpixelデータが欠けたJPEGを受け付けない" do
    bytes = image.write_to_buffer(".jpg")

    expect(readable?(bytes.byteslice(0, bytes.bytesize - 50), content_type: "image/jpeg")).to be(false)
  end

  it "画像として申告された任意の本文をdecoderへ渡さない" do
    expect(Vips::Image).not_to receive(:new_from_buffer)

    expect(readable?("<svg>private source</svg>", content_type: "image/png")).to be(false)
  end

  it "実際の形式と申告された形式が異なる画像を受け付けない" do
    expect(readable?(image.write_to_buffer(".png"), content_type: "image/jpeg")).to be(false)
  end

  it "未対応のcontent typeを受け付けない" do
    expect(readable?(image.write_to_buffer(".png"), content_type: "application/pdf")).to be(false)
  end

  it "byte上限と一致する正常画像を受け付ける" do
    bytes = image.write_to_buffer(".png")

    expect(readable?(bytes, content_type: "image/png", max_bytes: bytes.bytesize)).to be(true)
  end

  it "byte上限超過はpixelをdecodeせず拒否する" do
    bytes = image.write_to_buffer(".png")
    expect(Vips::Image).not_to receive(:new_from_buffer)

    expect(readable?(bytes, content_type: "image/png", max_bytes: bytes.bytesize - 1)).to be(false)
  end

  it "寸法上限を超える画像はpixelをdecodeせず拒否する" do
    bytes = image.write_to_buffer(".png")

    expect(readable?(bytes, content_type: "image/png", max_dimension: 159)).to be(false)
  end

  it "寸法上限と一致する正常画像を受け付ける" do
    expect(readable?(image.write_to_buffer(".png"), content_type: "image/png", max_dimension: 160)).to be(true)
  end

  it "呼び出し元のIO位置を変更せず閉じない" do
    io = StringIO.new(image.write_to_buffer(".png"))
    io.seek(17)

    expect(described_class.valid?(io:, content_type: "image/png", max_bytes:, max_dimension:)).to be(true)
    expect(io.pos).to eq(17)
    expect(io).not_to be_closed
  end

  it "読み込み失敗の本文を例外として返さない" do
    io = StringIO.new("private source")
    allow(io).to receive(:read).and_raise(IOError, "private source")

    expect(described_class.valid?(io:, content_type: "image/png", max_bytes:, max_dimension:)).to be(false)
  end

  it "decoderの例外本文を呼び出し元へ返さない" do
    bytes = image.write_to_buffer(".png")
    allow(Vips::Image).to receive(:new_from_buffer).and_raise(Vips::Error, "private source")

    expect(readable?(bytes, content_type: "image/png")).to be(false)
  end

  it "seekできない入力を読み進めない" do
    io = instance_double(IO)
    allow(io).to receive(:read)

    expect(described_class.valid?(io:, content_type: "image/png", max_bytes:, max_dimension:)).to be(false)
    expect(io).not_to have_received(:read)
  end

  it "空の画像を受け付けない" do
    expect(readable?("", content_type: "image/png")).to be(false)
  end

  it "壊れた画像でも呼び出し元のIO位置を戻す" do
    io = StringIO.new("broken")
    io.seek(2)

    expect(described_class.valid?(io:, content_type: "image/png", max_bytes:, max_dimension:)).to be(false)
    expect(io.pos).to eq(2)
  end

  it "正の整数でない上限を受け付けない" do
    expect(readable?("", content_type: "image/png", max_bytes: "20")).to be(false)
    expect(readable?("", content_type: "image/png", max_dimension: 0)).to be(false)
  end
end
