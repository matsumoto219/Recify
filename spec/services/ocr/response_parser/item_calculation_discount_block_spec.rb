require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ItemCalculationDiscountBlock do
  let(:profile) { ReceiptAnalysisProfiles.fetch('JPN') }

  it '同一連続blockのlabel・率・注記・行割引だけを関連付ける' do
    lines = [ '検証品', '¥502', '操作割引07', '30%', '(単品 -75)', '-150' ]
    result = described_class.call(lines:, profile:)

    expect(result).to include(rate: BigDecimal('0.30'), amount: 150)
    expect(result[:evidence]).to eq(
      rate: { line_index: 3, byte_offset: 0, byte_length: 2 },
      amount: { line_index: 5, byte_offset: 1, byte_length: 3 }
    )
  end

  it 'single lineの既存表記と全角componentのbyte位置を保持する' do
    result = described_class.call(lines: [ '値引 ２７％ －１４円' ], profile:)

    expect(result).to include(rate: BigDecimal('0.27'), amount: 14)
    expect(result[:evidence]).to eq(
      rate: { line_index: 0, byte_offset: 7, byte_length: 6 },
      amount: { line_index: 0, byte_offset: 20, byte_length: 6 }
    )
  end

  it 'labelと率が同じ行でも隣の負金額にだけ結合する' do
    expect(described_class.call(lines: [ '商品割引 27%', '-14' ], profile:)).to include(amount: 14)
  end

  it '非連続・複数block・注記だけ・小計・不正値を拒否する' do
    [
      [ '割引', '30%', '別商品', '-150' ],
      [ '割引 30% -150', '割引 20% -100' ],
      [ '割引 30% -150', '割引', '20%' ],
      [ '割引 30% -150', '-100' ],
      [ '割引', '30%', '(単品 -75)' ],
      [ '小計割引', '30%', '-150' ],
      [ '割引', '0%', '-150' ],
      [ '割引', '100%', '-150' ],
      [ '割引', '27.01%', '-150' ],
      [ '割引', '30%', '150' ],
      [ '割引', '30%', '-150', '-200' ],
      [ '割引', '30%', '-1000000000000' ]
    ].each do |lines|
      expect(described_class.call(lines:, profile:)).to be_nil
    end
  end

  it '件数・文字列上限と不正encodingを拒否する' do
    [ nil, Array.new(151, ''), [ 'x' * 4_097 ], [ "割引\0" ], [ "\xFF".b.force_encoding(Encoding::UTF_8) ] ].each do |lines|
      expect(described_class.call(lines:, profile:)).to be_nil
    end
  end

  it '注入profileのlabel以外へfallbackしない' do
    allow(profile).to receive(:ocr_item_calculation_discount_label_line_pattern).and_return(/\AONLY\z/)

    expect(described_class.call(lines: [ 'ONLY', '30%', '-150' ], profile:)).to include(amount: 150)
    expect(described_class.call(lines: [ '割引', '30%', '-150' ], profile:)).to be_nil
  end
end
