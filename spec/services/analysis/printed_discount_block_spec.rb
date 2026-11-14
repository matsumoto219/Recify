require 'rails_helper'

RSpec.describe Analysis::PrintedDiscountBlock do
  let(:profile) { ReceiptAnalysisProfiles.default }
  let(:lines) { [ '検証品A 600円', '小計', '600円', '半額', '2点', '-120円', '小計', '480円' ] }
  let(:proposal) { { kind: 'other', sign: 'discount', amount: 120, source_line_index: 5 } }

  def resolve(source_lines: lines, attributes: proposal, items: [], selected_profile: profile)
    described_class.call(proposal: attributes, lines: source_lines, items: items, profile: selected_profile)
  end

  it '金額を逆算せず、3行内のどの参照位置でも同じ負額tokenを返す' do
    original = Marshal.dump([ lines, proposal ])

    [ 3, 4, 5 ].each do |index|
      entry = resolve(attributes: proposal.merge(source_line_index: index))
      expect(entry[:line]).to include(line_index: 5, source_text: '-120円')
      expect(entry[:token]).to include(amount: 120, kind: :money, span_start: 0, span_end: 5)
    end
    expect(Marshal.dump([ lines, proposal ])).to eq(original)
  end

  it '前の小計と後の小計または合計が同じ行に金額を持つ形式も扱う' do
    [ '小計 480円', '合計 480円' ].each do |summary|
      entry = resolve(
        source_lines: [ '小計 600円', '半額値引', '2点', '-120円', summary ],
        attributes: proposal.merge(source_line_index: 1)
      )
      expect(entry[:line][:line_index]).to eq(3)
    end
  end

  it '後の小計や合計の金額前に数量だけの1行がある場合も同じ割引tokenを保持する' do
    [ '小計', '合計' ].each do |summary|
      entry = resolve(source_lines: [ *lines.first(6), summary, '2点', '480円' ])
      expect(entry[:line][:line_index]).to eq(5)
      expect(entry[:token][:amount]).to eq(120)
    end
  end

  it '後の集計から未知行、複数行、欠落額、負額を跨いで金額を探さない' do
    [
      [ '小計', '検証品B', '480円' ],
      [ '小計', '2点', '2点', '480円' ],
      [ '小計', '2点' ],
      [ '小計', '2点', '-480円' ]
    ].each do |summary|
      expect(resolve(source_lines: [ *lines.first(6), *summary ])).to be_nil
    end
  end

  it '厳密な3行blockの中間だけは単位なしの正整数を許容し、その値を金額にしない' do
    source_lines = lines.dup
    source_lines[4] = '2'
    expect(resolve(source_lines: source_lines)[:token][:amount]).to eq(120)

    [ '0', '-2', '2.0', '2%', '2 3', '10000', '12345678901234567890' ].each do |quantity|
      source_lines[4] = quantity
      expect(resolve(source_lines: source_lines)).to be_nil
    end
  end

  {
    'AIのlabelだけにある割引' => [ 3, '検証品B' ],
    '次回の販促' => [ 3, '次回半額' ],
    '数量の代わりの金額' => [ 4, '2円' ],
    '数量の代わりの率' => [ 4, '50%' ],
    '別の商品を含む数量' => [ 4, '検証品B 2点' ],
    '複数の数量' => [ 4, '2点 3点' ],
    '正符号の金額' => [ 5, '+120円' ],
    '符号のない金額' => [ 5, '120円' ],
    '複数金額' => [ 5, '-120円 -120円' ],
    '別itemの金額' => [ 5, '検証品B -120円' ],
    '後の支払ラベル' => [ 6, '現金' ],
    '後の税ラベル' => [ 6, '消費税' ],
    '後の小計金額欠損' => [ 7, '検証品B' ],
    '前の小計欠損' => [ 1, '検証品B' ]
  }.each do |description, (index, text)|
    it "#{description}から新しいblockを成立させない" do
      changed_lines = lines.dup
      changed_lines[index] = text
      expect(resolve(source_lines: changed_lines, attributes: proposal.merge(label: '半額'))).to be_nil
    end
  end

  it '数量行の欠落と別行を挟んだ配置から探索を広げない' do
    expect(resolve(source_lines: lines.reject.with_index { |_, index| index == 4 })).to be_nil
    expect(resolve(source_lines: lines.dup.insert(4, '検証品B'), attributes: proposal.merge(source_line_index: 6))).to be_nil
  end

  it '印字額と提案額の不一致、別種別、逆符号を新しい根拠にしない' do
    [ { amount: 121 }, { kind: 'coupon' }, { sign: 'surcharge' } ].each do |change|
      expect(resolve(attributes: proposal.merge(change))).to be_nil
    end
  end

  it 'AI labelの別owner主張を新しいblockの印字根拠として受理しない' do
    [ 'キャッシュレス還元', 'クーポン値引', 'ポイント利用', '税額', '別の半額' ].each do |label|
      expect(resolve(attributes: proposal.merge(label: label))).to be_nil
    end
    expect(resolve(attributes: proposal.merge(label: ' 半 額 '))).to be_present
    expect(resolve(attributes: proposal.merge(label: nil))).to be_present
  end

  it 'source textに指定行外の主張があれば新しいblockを根拠にしない' do
    [ 'クーポン 半額', 'キャッシュレス 半額', '半額 -120円' ].each do |source|
      expect(resolve(attributes: proposal.merge(source_line_index: 3, source_text: source))).to be_nil
    end
    expect(resolve(attributes: proposal.merge(source_line_index: 3, source_text: ' 半 額 '))).to be_present
  end

  it '明示spanは金額行のexact tokenだけを受理し、不完全なspanを推測しない' do
    expect(resolve(attributes: proposal.merge(source_span_start: 0, source_span_end: 5))).to be_present
    [
      { source_span_start: 0 }, { source_span_end: 5 },
      { source_span_start: '0', source_span_end: 5 },
      { source_span_start: -1, source_span_end: 5 },
      { source_span_start: 0, source_span_end: 4 },
      { source_line_index: 3, source_span_start: 0, source_span_end: 5 }
    ].each do |change|
      expect(resolve(attributes: proposal.merge(change))).to be_nil
    end
  end

  it '決済後に繰り返された小計や販促を購入調整へ戻さない' do
    expect(resolve(source_lines: [ '合計 600円', *lines ], attributes: proposal.merge(source_line_index: 6))).to be_nil
  end

  it 'itemが所有する同じ割引tokenをレシート全体の割引へ昇格しない' do
    reference = { source_line_index: 5, source_span_start: 0, source_span_end: 5, amount: 120 }
    expect(resolve(items: [ { discount_source_refs: [ reference ] } ])).to be_nil
    expect(resolve(items: [ { discount_source_refs: [ reference.merge(source_line_index: 0) ] } ])).to be_present
  end

  it '地域語彙は注入profileから読み、置換前の割引・数量・小計を使わない' do
    replacement = Module.new do
      define_singleton_method(:analysis_printed_discount_label_pattern) { /\AReduction\z/ }
      define_singleton_method(:analysis_printed_discount_quantity_pattern) { /\A[1-9][0-9]* units\z/ }
      define_singleton_method(:analysis_printed_discount_subtotal_label_pattern) { /\AIntermediate\z/ }
    end
    allow(replacement).to receive(:method_missing) { |method, *arguments| profile.public_send(method, *arguments) }
    allow(replacement).to receive(:respond_to_missing?).and_return(true)
    source_lines = [ 'Intermediate', '600円', 'Reduction', '2 units', '-120円', 'Intermediate', '480円' ]

    expect(resolve(source_lines: source_lines, attributes: proposal.merge(source_line_index: 4), selected_profile: replacement)).to be_present
    expect(resolve(selected_profile: replacement)).to be_nil
  end
end
