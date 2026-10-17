require "spec_helper"
require_relative "../../../app/services/storage"
require_relative "../../../app/services/storage/tiff_page_count"

RSpec.describe Storage::TiffPageCount do
  def tiff_bytes(endian: "II", bigtiff: false, pages: 2)
    short = endian == "II" ? "v" : "n"
    long = endian == "II" ? "V" : "N"
    offset = bigtiff ? (endian == "II" ? "Q<" : "Q>") : long
    header_size = bigtiff ? 16 : 8
    directory_size = bigtiff ? 36 : 18
    header = endian.b + [ bigtiff ? 43 : 42 ].pack(short)
    header += [ 8, 0 ].pack("#{short}2") if bigtiff
    header += [ header_size ].pack(offset)
    directories = pages.times.map do |index|
      entry = [ 256, 4 ].pack("#{short}2") + [ 1 ].pack(bigtiff ? offset : long) + [ 120 ].pack(offset)
      next_offset = index == pages - 1 ? 0 : header_size + (index + 1) * directory_size
      [ 1 ].pack(bigtiff ? offset : short) + entry + [ next_offset ].pack(offset)
    end
    header + directories.join
  end

  %w[II MM].each do |endian|
    [ false, true ].each do |bigtiff|
      it "#{endian}の#{bigtiff ? 'BigTIFF' : 'TIFF'}の全directoryを数える" do
        expect(described_class.call(tiff_bytes(endian:, bigtiff:))).to eq(2)
      end
    end
  end

  it "単一ページの正常終端を認識する" do
    expect(described_class.call(tiff_bytes(pages: 1))).to eq(1)
  end

  it "ページ上限ちょうどを受け付け、超過を拒否する" do
    stub_const("Storage::TiffPageCount::MAX_PAGES", 2)

    expect(described_class.call(tiff_bytes(pages: 2))).to eq(2)
    expect(described_class.call(tiff_bytes(pages: 3))).to be_nil
  end

  it "後続directoryのnext pointerが欠けていれば拒否する" do
    bytes = tiff_bytes

    expect(described_class.call(bytes.byteslice(0, bytes.bytesize - 1))).to be_nil
  end

  it "directoryのentry数が本文の範囲を超えれば拒否する" do
    bytes = tiff_bytes
    bytes[26, 2] = [ 65_535 ].pack("v")

    expect(described_class.call(bytes)).to be_nil
  end

  it "本文の外を指すnext pointerを拒否する" do
    bytes = tiff_bytes
    bytes[22, 4] = [ bytes.bytesize ].pack("V")

    expect(described_class.call(bytes)).to be_nil
  end

  it "directoryの循環参照を拒否する" do
    bytes = tiff_bytes
    bytes[40, 4] = [ 8 ].pack("V")

    expect(described_class.call(bytes)).to be_nil
  end

  it "header内を指すdirectoryを拒否する" do
    bytes = tiff_bytes
    bytes[4, 4] = [ 4 ].pack("V")

    expect(described_class.call(bytes)).to be_nil
  end

  it "最初のdirectoryがない画像を拒否する" do
    bytes = tiff_bytes
    bytes[4, 4] = [ 0 ].pack("V")

    expect(described_class.call(bytes)).to be_nil
  end

  it "entryのないdirectoryを拒否する" do
    bytes = tiff_bytes
    bytes[8, 2] = [ 0 ].pack("v")

    expect(described_class.call(bytes)).to be_nil
  end

  it "BigTIFFの未対応offset幅を拒否する" do
    bytes = tiff_bytes(bigtiff: true)
    bytes[4, 2] = [ 4 ].pack("v")

    expect(described_class.call(bytes)).to be_nil
  end

  it "BigTIFFの予約領域が非zeroなら拒否する" do
    bytes = tiff_bytes(bigtiff: true)
    bytes[6, 2] = [ 1 ].pack("v")

    expect(described_class.call(bytes)).to be_nil
  end

  it "BigTIFFの巨大entry数を配列展開せず拒否する" do
    bytes = tiff_bytes(bigtiff: true)
    bytes[16, 8] = [ (2**64) - 1 ].pack("Q<")

    expect(described_class.call(bytes)).to be_nil
  end

  it "BigTIFFの巨大offsetを拒否する" do
    bytes = tiff_bytes(bigtiff: true)
    bytes[8, 8] = [ (2**64) - 1 ].pack("Q<")

    expect(described_class.call(bytes)).to be_nil
  end

  it "壊れたheaderと文字列以外の入力を拒否する" do
    [ nil, {}, "", "II", "MM\0*", "ZZ" + tiff_bytes.byteslice(2..), "II\0\0" + tiff_bytes.byteslice(4..) ].each do |bytes|
      expect(described_class.call(bytes)).to be_nil
    end
  end
end
