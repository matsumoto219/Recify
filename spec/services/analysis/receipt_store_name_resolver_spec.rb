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

  it '店舗名解決と選択肢構成だけをpublic class methodとして公開する' do
    expect(described_class.singleton_class.public_instance_methods(false)).to contain_exactly(:call, :resolve, :options)
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

  it '採用した店舗名を含む宣伝行へ選択後に拡張しない' do
    expect(resolve_store_name(
      store_name: 'SampleMart',
      lines: [ 'SampleMart', 'SampleMart ご利用ありがとうございます' ]
    )).to eq('SampleMart')
  end

  it 'ブランドと区切られた支店名が同じ行にある場合は印字済みoptionを選ぶ' do
    expect(resolve_store_name(
      store_name: 'SampleMart',
      lines: [ 'SampleMart 松風店', '領収書' ]
    )).to eq('SampleMart 松風店')
  end

  describe '.resolve' do
    let(:ocr_result) do
      { candidates: { store_name: 'サンプルストア', items: [] }, lines: [ 'サンプルストア', '領収書' ] }
    end

    def evidence_result(*entries, truncated: false)
      ocr_result.deep_merge(candidates: {
        store_name_evidence: {
          schema_version: 'store_name_evidence_v1', candidates: entries, truncated: truncated, invalid: false
        }
      })
    end

    def line_candidate(text, index = 0)
      {
        candidate_id: "line_#{index}", text: text, source: 'line',
        source_path: "lines[#{index}]", line_index: index, span_state: 'missing'
      }
    end

    def page_candidate(text, index, page: 0, offset: index * 30)
      {
        candidate_id: "page_#{page}_line_#{index}", text: text, source: 'line',
        source_path: "pages[#{page}].lines[#{index}]", line_index: index,
        page_index: page, provider_line_index: index, span_state: 'exact',
        span: { offset: offset, length: text.length }, string_index_type: 'textElements'
      }
    end

    it '施設と用途のexact連続行を参考候補と同じ完全名で選択可能にする' do
      input = evidence_result(page_candidate('サンプル公園', 0), page_candidate('駐車場', 1))
      options = described_class.options(ocr_result: input)

      expect(options[:options]).to include(
        include(value: 'サンプル公園駐車場', candidate_ids: [ 'page_0_line_0', 'page_0_line_1' ])
      )
    end

    it '店で終わらない施設名もexact見出しblock内だけでブランドと結合する' do
      input = evidence_result(page_candidate('サンプルレストラン', 0), page_candidate('みどりプラザ', 1))

      expect(described_class.options(ocr_result: input)[:options]).to include(
        include(value: 'サンプルレストラン みどりプラザ')
      )
    end

    it '複数行MerchantNameに覆われたブランドと後続支店を同じsupportで合成する' do
      merchant = {
        candidate_id: 'merchant_name', text: 'サンプルの 食堂', source: 'merchant_name',
        source_path: 'documents[0].fields.MerchantName', confidence: 0.99,
        span_state: 'exact', span: { offset: 0, length: 32 }, string_index_type: 'textElements'
      }
      input = evidence_result(
        merchant, page_candidate('サンプルの', 0), page_candidate('食堂', 1), page_candidate('中央店', 2)
      )
      options = described_class.options(ocr_result: input)[:options]

      aggregate_failures do
        expect(options).to include(include(value: 'サンプルの 食堂', confidence: 0.99))
        expect(options).to include(
          include(
            value: 'サンプルの 食堂 中央店',
            candidate_ids: [ 'merchant_name', 'page_0_line_0', 'page_0_line_1', 'page_0_line_2' ]
          )
        )
        expect(options.find { |option| option[:value] == 'サンプルの 食堂 中央店' }).not_to have_key(:confidence)
      end
    end

    it '一文字候補を残しても後続の完全なMerchantNameへ付け足さない' do
      name = 'サンプル食堂 中央店'
      merchant = {
        candidate_id: 'merchant_name', text: name, source: 'merchant_name',
        source_path: 'documents[0].fields.MerchantName', confidence: 0.99,
        span_state: 'exact', span: { offset: 30, length: name.length }, string_index_type: 'textElements', line_index: 1
      }
      input = evidence_result(merchant, page_candidate('一', 0), page_candidate(name, 1))
      options = described_class.options(ocr_result: input)[:options]

      aggregate_failures do
        expect(options).to include(include(value: name, confidence: 0.99), include(value: '一'))
        expect(options).not_to include(include(value: "一 #{name}"))
      end
    end

    it '同名でも別blockの行を合成候補の出典へ取り込まない' do
      input = evidence_result(
        page_candidate('SampleMart', 0), page_candidate('中央店', 1), page_candidate('SampleMart', 6)
      )
      option = described_class.options(ocr_result: input)[:options].find { |candidate| candidate[:value] == 'SampleMart 中央店' }

      expect(option).to include(candidate_ids: [ 'page_0_line_0', 'page_0_line_1' ], line_indexes: [ 0, 1 ])
    end

    {
      '別page' => { page_index: 1, provider_line_index: 0, candidate_id: 'page_1_line_0', source_path: 'pages[1].lines[0]' },
      '非連続provider行' => { provider_line_index: 3, candidate_id: 'page_0_line_3', source_path: 'pages[0].lines[3]' },
      '非連続normalized行' => { line_index: 3 },
      'span overlap' => { span: { offset: 2, length: 3 } },
      '異なるindex type' => { string_index_type: 'utf16CodeUnit' },
      '逆順span' => { span: { offset: 0, length: 3 } }
    }.each do |label, changes|
      it "#{label}の行を単なる近接で店舗名へ結合しない" do
        input = evidence_result(page_candidate('SampleMart', 0, offset: 10), page_candidate('中央店', 1).merge(changes))

        expect(described_class.options(ocr_result: input)[:options]).not_to include(include(value: 'SampleMart 中央店'))
      end
    end

    it '別の完成店舗名を連続していても一つの店舗へ結合しない' do
      [ [ '青葉商店', '朝日商店' ], [ 'サンプルストア', '青葉ストア' ] ].each do |names|
        input = evidence_result(*names.each_with_index.map { |name, index| page_candidate(name, index) })

        expect(described_class.options(ocr_result: input)[:options].map { |option| option[:value] }).to match_array(names)
      end
    end

    it 'MerchantName根拠なしに三行の見出しを一つへ連結しない' do
      input = evidence_result(page_candidate('青葉', 0), page_candidate('みどり', 1), page_candidate('中央店', 2))

      expect(described_class.options(ocr_result: input)[:options]).not_to include(
        include(value: '青葉みどり中央店'), include(value: '青葉 みどり 中央店')
      )
    end

    it '複数行MerchantNameの直後でも支店でない行を追加しない' do
      merchant = {
        candidate_id: 'merchant_name', text: 'サンプルの 食堂', source: 'merchant_name',
        source_path: 'documents[0].fields.MerchantName', confidence: 0.99,
        span_state: 'exact', span: { offset: 0, length: 32 }, string_index_type: 'textElements'
      }
      input = evidence_result(
        merchant, page_candidate('サンプルの', 0), page_candidate('食堂', 1), page_candidate('サンプルサービス', 2)
      )

      expect(described_class.options(ocr_result: input)[:options]).not_to include(
        include(value: 'サンプルの 食堂 サンプルサービス')
      )
    end

    it 'exact spanがないpage行から新しい見出し結合を行わない' do
      first = page_candidate('サンプル公園', 0).except(:span, :string_index_type).merge(span_state: 'missing')
      input = evidence_result(first, page_candidate('駐車場', 1))

      expect(described_class.options(ocr_result: input)[:options].map { |option| option[:value] }).to contain_exactly('サンプル公園', '駐車場')
    end

    it '宣伝行を挟む見出しを同じblockとして結合しない' do
      input = evidence_result(
        page_candidate('サンプル公園', 0), page_candidate('毎日安い!この価格!', 1), page_candidate('駐車場', 2)
      )

      expect(described_class.options(ocr_result: input)[:options].map { |option| option[:value] }).to contain_exactly('サンプル公園', '駐車場')
    end

    it '商品点数を店舗候補へ残さず点を含む店舗名は維持する' do
      input = evidence_result(page_candidate('3点', 0), page_candidate('三点商店', 1))

      expect(described_class.options(ocr_result: input)[:options].map { |option| option[:value] }).to eq([ '三点商店' ])
    end

    it 'spanのない旧page evidenceは従来の印字行支持と確認済み状態を維持する' do
      name = 'サンプル検証ストア'
      merchant = {
        candidate_id: 'merchant_name', text: name, source: 'merchant_name',
        source_path: 'documents[0].fields.MerchantName', span_state: 'missing'
      }
      line = page_candidate(name, 0).except(:span, :string_index_type).merge(span_state: 'missing')
      input = evidence_result(merchant, line)

      result = described_class.resolve(ocr_result: input, ai_result: { receipt_attributes: { store_name: name } })

      expect(result).to include(value: name, state: 'confirmed', reason_codes: [])
    end

    it 'invalid spanを除外した残りのmissing行を旧合成経路へ逃がさない' do
      entries = [ page_candidate('SampleMart', 0), page_candidate('中央店', 1) ].map do |entry|
        entry.except(:span, :string_index_type).merge(span_state: 'missing')
      end
      invalid = page_candidate('別名', 2).except(:span, :string_index_type).merge(span_state: 'invalid')

      expect(described_class.options(ocr_result: evidence_result(*entries, invalid))[:options]).not_to include(
        include(value: 'SampleMart 中央店'), include(value: '別名')
      )
    end

    it 'exact MerchantNameと支店の間に印字されたロゴ断片がある既存候補を維持する' do
      name = 'サンプルストア'
      merchant = {
        candidate_id: 'merchant_name', text: name, source: 'merchant_name',
        source_path: 'documents[0].fields.MerchantName', span_state: 'exact',
        span: { offset: 0, length: name.length }, string_index_type: 'textElements'
      }
      input = evidence_result(merchant, page_candidate(name, 0), page_candidate('ABC XY', 1), page_candidate('中央店', 2))

      expect(described_class.options(ocr_result: input)[:options]).to include(
        include(value: 'サンプルストア 中央店', candidate_ids: [ 'merchant_name', 'page_0_line_0', 'page_0_line_1', 'page_0_line_2' ])
      )
    end

    it 'MerchantNameがあっても別の完成店舗や一文字候補を飛ばして支店へ結合しない' do
      name = 'サンプルストア'
      merchant = {
        candidate_id: 'merchant_name', text: name, source: 'merchant_name',
        source_path: 'documents[0].fields.MerchantName', span_state: 'exact',
        span: { offset: 0, length: name.length }, string_index_type: 'textElements'
      }
      [ '青葉商店', '北口店', 'Q', '領収書' ].each do |middle|
        input = evidence_result(merchant, page_candidate(name, 0), page_candidate(middle, 1), page_candidate('中央店', 2))

        expect(described_class.options(ocr_result: input)[:options]).not_to include(include(value: 'サンプルストア 中央店'))
      end
    end

    it 'ブランドに既に含まれる単独symbolの重複行を支店名へ挟まない' do
      input = evidence_result(page_candidate('SampleMart®', 0), page_candidate('®', 1), page_candidate('中央店', 2))

      expect(described_class.options(ocr_result: input)[:options]).to include(
        include(value: 'SampleMart® 中央店', candidate_ids: [ 'page_0_line_0', 'page_0_line_1', 'page_0_line_2' ])
      )
    end

    it '独立した一文字ブランドや異なるsymbolを重複ロゴとして飛ばさない' do
      [ 'Q', '©' ].each do |middle|
        input = evidence_result(page_candidate('SampleMart®', 0), page_candidate(middle, 1), page_candidate('中央店', 2))

        expect(described_class.options(ocr_result: input)[:options]).not_to include(include(value: 'SampleMart® 中央店'))
      end
    end

    context 'Latin logoと業態と支店の既存復元' do
      let(:logo_entries) do
        [ 'samplecacaok', 'maitre sample suisse', 'since 1900', 'サムプル ショコラ ブティック&カフェ', '中央店', '', '', 'www.samplecacao.jp' ]
          .each_with_index.filter_map { |text, index| page_candidate(text, index) if text.present? }
      end

      it '同page headerの使用した行だけを出典に従来のlogo表記を復元する' do
        options = described_class.options(ocr_result: evidence_result(*logo_entries))[:options]

        expect(options).to include(
          include(
            value: 'Samplecacao ショコラブティック&カフェ 中央店',
            candidate_ids: [ 'page_0_line_0', 'page_0_line_3', 'page_0_line_4', 'page_0_line_7' ]
          )
        )
      end

      it 'header外でも同pageのexact domainだけを既存logo補正の出典に使う' do
        logo_entries[-1] = page_candidate('www.samplecacao.jp', 47)

        expect(described_class.options(ocr_result: evidence_result(*logo_entries))[:options]).to include(
          include(
            value: 'Samplecacao ショコラブティック&カフェ 中央店',
            candidate_ids: [ 'page_0_line_0', 'page_0_line_3', 'page_0_line_4', 'page_0_line_47' ]
          )
        )
      end

      it '別pageのdomainをlogo補正へ使用しない' do
        logo_entries.last.merge!(page_index: 1, provider_line_index: 0, source_path: 'pages[1].lines[0]', candidate_id: 'page_1_line_0')

        expect(described_class.options(ocr_result: evidence_result(*logo_entries))[:options]).not_to include(
          include(value: 'Samplecacao ショコラブティック&カフェ 中央店')
        )
      end

      it '別の完成店舗名をまたいでlogoと業態を関連付けない' do
        logo_entries[1] = page_candidate('サンプルストア 北口店', 1)

        expect(described_class.options(ocr_result: evidence_result(*logo_entries))[:options]).not_to include(
          include(value: 'Samplecacao ショコラブティック&カフェ 中央店')
        )
      end

      it '同じheaderに複数の独立したlogoがある場合は補正を選ばない' do
        logo_entries[1] = page_candidate('OtherBrand', 1)

        expect(described_class.options(ocr_result: evidence_result(*logo_entries))[:options]).not_to include(
          include(value: 'Samplecacao ショコラブティック&カフェ 中央店')
        )
      end

      it '複数のdomain根拠を任意に選んでlogoを補正しない' do
        logo_entries << page_candidate('www.samplecacao.com', 47)

        expect(described_class.options(ocr_result: evidence_result(*logo_entries))[:options]).not_to include(
          include(value: 'Samplecacao ショコラブティック&カフェ 中央店')
        )
      end

      it 'exactでないfooter domainをlogoの補正根拠にしない' do
        logo_entries[-1] = page_candidate('www.samplecacao.jp', 47)
          .except(:span, :string_index_type).merge(span_state: 'missing')

        expect(described_class.options(ocr_result: evidence_result(*logo_entries))[:options]).not_to include(
          include(value: 'Samplecacao ショコラブティック&カフェ 中央店')
        )
      end

      it 'header外の同じ行構造をlogo復元へ流用しない' do
        entries = logo_entries.map { |entry| page_candidate(entry[:text], entry[:provider_line_index] + 10) }

        expect(described_class.options(ocr_result: evidence_result(*entries))[:options]).not_to include(
          include(value: 'Samplecacao ショコラブティック&カフェ 中央店')
        )
      end
    end

    it '不正なAI店舗名で有効なOCR店舗名を失わない' do
      result = described_class.resolve(
        ocr_result: ocr_result,
        ai_result: { receipt_attributes: { store_name: '領収書' } }
      )

      expect(result).to include(value: 'サンプルストア', state: 'confirmed', reason_codes: [])
    end

    it 'OCRにない自由生成名を採用しない' do
      result = described_class.resolve(
        ocr_result: ocr_result,
        ai_result: { receipt_attributes: { store_name: '架空の補正名' } }
      )

      expect(result[:value]).to eq('サンプルストア')
    end

    it 'AI選択後には同じoptionの値だけを返す' do
      options = described_class.options(ocr_result: ocr_result)
      selected = options[:options].first
      result = described_class.resolve(
        ocr_result: ocr_result,
        ai_result: {
          meta: { store_name_selection: { decision: 'select', option_id: selected[:option_id], options_checksum: options[:checksum] } }
        }
      )

      expect(result).to include(value: selected[:value], option_id: selected[:option_id], state: 'confirmed')
    end

    it '不正な明示evidenceからlegacy候補へ戻らない' do
      result = described_class.resolve(ocr_result: ocr_result.deep_merge(candidates: { store_name_evidence: { invalid: true } }))

      expect(result).to include(value: nil, state: 'missing', reason_codes: [ 'store_name_missing' ])
    end

    it '省略された候補集合を一意な確定候補と扱わない' do
      result = described_class.resolve(ocr_result: evidence_result(line_candidate('サンプルストア'), truncated: true))

      expect(result).to include(value: 'サンプルストア', state: 'uncertain', reason_codes: [ 'store_name_uncertain' ])
    end

    it '同じoption IDでもchecksumが異なるAI選択を採用しない' do
      input = evidence_result(line_candidate('サンプルストア'), line_candidate('別の商店', 1))
        .merge(lines: [ 'サンプルストア', '別の商店' ])
      options = described_class.options(ocr_result: input)
      other = options[:options].find { |option| option[:value] == '別の商店' }
      result = described_class.resolve(
        ocr_result: input,
        ai_result: { meta: { store_name_selection: { decision: 'select', option_id: other[:option_id], options_checksum: 'a' * 64 } } }
      )

      expect(result[:value]).to eq('サンプルストア')
    end

    it 'MerchantNameのconfidenceを別の合成名へコピーしない' do
      merchant = {
        candidate_id: 'merchant_name', text: 'SampleMart', source: 'merchant_name',
        source_path: 'documents[0].fields.MerchantName', confidence: 0.99, span_state: 'missing'
      }
      input = evidence_result(merchant, line_candidate('SampleMart'), line_candidate('東京中央店', 1), truncated: true)
        .merge(lines: [ 'SampleMart', '東京中央店' ])

      options = described_class.options(ocr_result: input)
      result = described_class.resolve(ocr_result: input)

      aggregate_failures do
        expect(options[:options].first).not_to have_key(:confidence)
        expect(result).to include(value: 'SampleMart 東京中央店', state: 'uncertain')
      end
    end

    it '他候補の省略だけで強いatomic MerchantNameへ常時reviewを追加しない' do
      merchant = {
        candidate_id: 'merchant_name', text: 'サンプルストア', source: 'merchant_name',
        source_path: 'documents[0].fields.MerchantName', confidence: 0.99, span_state: 'missing'
      }
      result = described_class.resolve(ocr_result: evidence_result(merchant, truncated: true))

      expect(result).to include(value: 'サンプルストア', state: 'confirmed', reason_codes: [])
    end

    it 'invalid spanをmissing evidenceとして採用しない' do
      input = evidence_result(line_candidate('サンプルストア').merge(span_state: 'invalid'))

      expect(described_class.resolve(ocr_result: input)).to include(value: nil, state: 'missing')
    end

    it '同じ証拠から安定したoption IDとchecksumを構成し入力を変更しない' do
      input = evidence_result(line_candidate('サンプルストア'))
      original = input.deep_dup

      expect(described_class.options(ocr_result: input)).to eq(described_class.options(ocr_result: input.deep_dup))
      expect(input).to eq(original)
    end

    it '新しい挨拶除外は注入されたprofileを参照する' do
      replacement = ReceiptAnalysisProfiles.default.dup
      replacement.define_singleton_method(:ai_store_greeting_noise_pattern) { /replacement_noise/ }

      aggregate_failures do
        expect(described_class.resolve(ocr_result: { candidates: { store_name: 'replacement_noise' } }, profile: replacement)[:value]).to be_nil
        expect(described_class.resolve(ocr_result: { candidates: { store_name: 'thank you shop' } }, profile: replacement)[:value]).to eq('thank you shop')
      end
    end

    it '無関係な複数店舗の先頭を文字列一致だけで確認済みにしない' do
      input = evidence_result(line_candidate('青葉商店'), line_candidate('朝日商店', 1))
        .deep_merge(candidates: { store_name: '青葉商店' }, lines: [ '青葉商店', '朝日商店' ])

      result = described_class.resolve(ocr_result: input)

      expect(result).to include(value: '青葉商店', state: 'uncertain', reason_codes: [ 'store_name_uncertain' ])
    end

    it 'ブランドの証拠を共有していても異なる完成名の支店候補を確認済みにしない' do
      input = evidence_result(
        line_candidate('青葉屋'), line_candidate('松風通り', 1), line_candidate('若葉通り', 3)
      ).deep_merge(candidates: { store_name: '青葉屋' }, lines: [ '青葉屋', '松風通り', '', '若葉通り' ])

      result = described_class.resolve(ocr_result: input)

      expect(result).to include(state: 'uncertain', reason_codes: [ 'store_name_uncertain' ])
    end

    it '異なる店舗候補を検証済みIDで選択した場合だけ曖昧さを解消する' do
      input = evidence_result(line_candidate('青葉商店'), line_candidate('朝日商店', 1))
        .merge(lines: [ '青葉商店', '朝日商店' ])
      options = described_class.options(ocr_result: input)
      selected = options[:options].find { |option| option[:value] == '朝日商店' }

      result = described_class.resolve(
        ocr_result: input,
        ai_result: { meta: { store_name_selection: { decision: 'select', option_id: selected[:option_id], options_checksum: options[:checksum] } } }
      )

      expect(result).to include(value: '朝日商店', state: 'confirmed', reason_codes: [])
    end

    it 'typed pathとline indexが矛盾したcandidate associationを利用しない' do
      input = evidence_result(line_candidate('誤関連ストア').merge(source_path: 'lines[1]'))

      expect(described_class.resolve(ocr_result: input)).to include(value: nil, state: 'missing')
    end

    it '汎用linesが短縮されてもtyped evidenceのoption identityを維持する' do
      name = ('青葉' * 20) + '商店'
      input = evidence_result(line_candidate(name)).merge(lines: [ name ])
      snapshot = input.merge(lines: [ name[0, 30] ])

      aggregate_failures do
        expect(described_class.options(ocr_result: snapshot)).to eq(described_class.options(ocr_result: input))
        expect(described_class.resolve(ocr_result: snapshot)).to include(value: name, state: 'confirmed')
      end
    end

    it '異なるtyped lineが同じnormalized positionを占める場合は候補を採用しない' do
      other = line_candidate('別の商店').merge(
        candidate_id: 'page_0_line_1', page_index: 0, provider_line_index: 1, source_path: 'pages[0].lines[1]'
      )
      input = evidence_result(line_candidate('サンプルストア'), other)

      expect(described_class.resolve(ocr_result: input)).to include(value: nil, state: 'missing')
    end

    it '既存の電話suffixだけを除去した支店候補を同じ原文行へ関連付ける' do
      input = evidence_result(line_candidate('サンプルストア'), line_candidate('東京中央店', 1))
        .merge(lines: [ 'サンプルストア', '東京中央店 TEL: 000-000-0000' ])

      options = described_class.options(ocr_result: input)

      aggregate_failures do
        expect(options[:options]).to include(include(value: 'サンプルストア 東京中央店', candidate_ids: [ 'line_0', 'line_1' ]))
        expect(options.to_json).not_to include('000-000-0000')
      end
    end

    it '既存snapshotの安全上限内なら150行より後の店舗evidenceを保持する' do
      input = evidence_result(line_candidate('青葉商店', 999))
        .merge(lines: Array.new(999, '') + [ '青葉商店' ])

      expect(described_class.resolve(ocr_result: input)).to include(value: '青葉商店', state: 'confirmed')
    end

    it '既存snapshotの安全上限を超えた行は店舗evidenceへ利用しない' do
      input = evidence_result(line_candidate('青葉商店', 1000))
        .merge(lines: Array.new(1000, '') + [ '青葉商店' ])

      expect(described_class.resolve(ocr_result: input)).to include(value: nil, state: 'missing')
    end

    it 'item名と同名でも店舗header自身のexact MerchantNameを排除しない' do
      merchant = {
        candidate_id: 'merchant_name', text: 'サンプルストア', source: 'merchant_name', source_path: 'documents[0].fields.MerchantName',
        confidence: 0.99, span_state: 'exact', span: { offset: 0, length: 8 }, string_index_type: 'utf16CodeUnit', line_index: 0
      }
      input = evidence_result(merchant).deep_merge(candidates: { items: [ { raw_text: 'サンプルストア' } ] })

      expect(described_class.resolve(ocr_result: input)).to include(value: 'サンプルストア', state: 'confirmed')
    end

    it '不正encodingと制御文字の店舗名でraiseや自由なfallbackを起こさない' do
      invalid = "\xFF".dup.force_encoding(Encoding::UTF_8)

      [ invalid, "店舗\u0000", 'a' * 501, [ '店舗' ] ].each do |value|
        result = described_class.resolve(ocr_result: { candidates: { store_name: value }, lines: [ value ] })

        expect(result).to include(value: nil, state: 'missing')
      end
    end

    it '法人名と直後の支店名を選択前に出典付きのbrand optionへ合成する' do
      input = evidence_result(
        line_candidate('株式会社青葉屋', 1), line_candidate('松風通り', 2)
      ).merge(lines: [ '誤字', '株式会社青葉屋', '松風通り', '住所' ])
      options = described_class.options(ocr_result: input)

      expect(options[:options]).to include(include(value: '青葉屋 松風通り', candidate_ids: [ 'line_1', 'line_2' ]))
    end

    it '国別registryの差替えprofileを使いunsupported countryへfallbackしない' do
      replacement = ReceiptAnalysisProfiles.default.dup
      replacement.define_singleton_method(:store_message_line_pattern) { /replacement_noise/ }
      stub_const('ReceiptAnalysisProfiles::Registry::SUPPORTED_COUNTRY_CODES', { 'TST' => replacement })

      supported = described_class.resolve(ocr_result: { candidates: { store_name: 'replacement_noise', country_region: 'TST' } })
      unsupported = described_class.options(ocr_result: { candidates: { store_name: 'サンプルストア', country_region: 'USA' } })

      aggregate_failures do
        expect(supported).to include(value: nil, state: 'missing')
        expect(unsupported).to include(options: [], invalid: true)
      end
    end
  end
end
