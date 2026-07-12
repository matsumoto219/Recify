require 'rails_helper'

RSpec.describe Analysis::ReceiptStoreNameResolver do
  before do
    allow(SystemSettings).to receive(:limit_for).and_return(12)
  end

  def resolve_store_name(**overrides)
    described_class.call(
      store_name: 'サンプルストア',
      lines: [],
      case_preserved_lines: [],
      **overrides
    )
  end

  it 'callだけをpublic class methodとして公開する' do
    expect(described_class.singleton_class.public_instance_methods(false)).to contain_exactly(:call)
  end

  it '空の店舗名ではcasing設定を読まず元の値を返す' do
    expect(SystemSettings).not_to receive(:limit_for)

    aggregate_failures do
      expect(resolve_store_name(store_name: nil)).to be_nil
      expect(resolve_store_name(store_name: '   ')).to eq('   ')
    end
  end

  it 'item名や帳票見出しを店舗名として採用しない' do
    aggregate_failures do
      expect(
        resolve_store_name(
          store_name: 'サンプル商品',
          lines: [ 'サンプル商品', '100円' ],
          item_names: [ 'サンプル商品' ],
          ai_store_name: true
        )
      ).to be_nil
      expect(
        resolve_store_name(
          store_name: '領 収 書',
          lines: [ '領 収 書', '合計 100円' ],
          ai_store_name: true
        )
      ).to be_nil
    end
  end

  it 'ブランドだけの候補へ印字された支店名を補う' do
    result = resolve_store_name(
      store_name: 'SampleMart',
      lines: [ 'SampleMart', '東京中央店', '領収証' ],
      ai_store_name: true
    )

    expect(result).to eq('SampleMart 東京中央店')
  end

  it 'ロゴと業態と支店をURLの根拠を使って自然な店舗名へ補う' do
    result = resolve_store_name(
      store_name: 'サムプル ショコラ ブティック&カフェ 青山po店',
      lines: [
        'samplecacaok',
        'maitre sample suisse',
        'since 1845',
        'サムプル ショコラ ブティック&カフェ',
        '青山po店',
        '107-0000',
        'サンプル区青山 1 青山po 1110区',
        'www.samplecacao.jp'
      ],
      ai_store_name: true
    )

    expect(result).to eq('Samplecacao ショコラブティック&カフェ 青山po店')
  end

  it 'case-preserved行から採用済み店舗名のcasingだけを復元する' do
    result = resolve_store_name(
      store_name: 'familymart 国分寺南町三丁目店',
      case_preserved_lines: [ 'FamilyMart 国分寺南町三丁目店' ]
    )

    expect(result).to eq('FamilyMart 国分寺南町三丁目店')
  end

  it 'casing参照行数が0または対象行より前までなら表記を変更しない' do
    allow(SystemSettings).to receive(:limit_for).and_return(0, 1)

    disabled = resolve_store_name(
      store_name: 'familymart 国分寺南町三丁目店',
      case_preserved_lines: [ 'FamilyMart 国分寺南町三丁目店' ]
    )
    limited = resolve_store_name(
      store_name: 'familymart 国分寺南町三丁目店',
      case_preserved_lines: [ '領収証', 'FamilyMart 国分寺南町三丁目店' ]
    )

    aggregate_failures do
      expect(disabled).to eq('familymart 国分寺南町三丁目店')
      expect(limited).to eq('familymart 国分寺南町三丁目店')
    end
  end

  it 'casing設定の取得に失敗した場合は既定の12行を使う' do
    allow(SystemSettings).to receive(:limit_for).and_raise(SystemSettings::UnknownKeyError)

    result = resolve_store_name(
      store_name: 'familymart 国分寺南町三丁目店',
      case_preserved_lines: [ 'FamilyMart 国分寺南町三丁目店' ]
    )

    expect(result).to eq('FamilyMart 国分寺南町三丁目店')
  end

  it 'URLや未採用ブランドをcase-preserved行から店舗名へ追加しない' do
    aggregate_failures do
      expect(
        resolve_store_name(
          store_name: 'samplemart',
          case_preserved_lines: [ 'www.SampleMart.com' ]
        )
      ).to eq('samplemart')
      expect(
        resolve_store_name(
          store_name: '中央店',
          case_preserved_lines: [ 'UnknownBrand', '中央店' ]
        )
      ).to eq('中央店')
    end
  end

  it '入力値を変更しない' do
    lines = [ 'SampleMart', '東京中央店' ]
    case_preserved_lines = [ 'SampleMart', '東京中央店' ]
    item_names = [ 'サンプル商品' ]
    original = [ lines.deep_dup, case_preserved_lines.deep_dup, item_names.deep_dup ]

    resolve_store_name(
      store_name: 'SampleMart',
      lines: lines,
      case_preserved_lines: case_preserved_lines,
      item_names: item_names,
      ai_store_name: true
    )

    expect([ lines, case_preserved_lines, item_names ]).to eq(original)
  end
end
