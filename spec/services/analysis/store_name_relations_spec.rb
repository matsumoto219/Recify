require 'rails_helper'

RSpec.describe Analysis::StoreNameRelations do
  def result_for(lines, page: 0)
    {
      success: true, lines: lines, case_preserved_lines: lines,
      candidates: {
        store_name: lines.first,
        store_name_evidence: {
          schema_version: 'store_name_evidence_v1', invalid: false, truncated: false,
          candidates: lines.each_with_index.map do |text, index|
            {
              candidate_id: "page_#{page}_line_#{index}", source: 'line', source_path: "pages[#{page}].lines[#{index}]",
              line_index: index, page_index: page, provider_line_index: index, text: text,
              span_state: 'exact', span: { offset: index * 40, length: text.length }, string_index_type: 'textElements'
            }
          end
        }
      }
    }
  end

  def options_for(input)
    Analysis.store_name_options(ocr_result: input, version: 'store_name_options_v2')
  end

  it '接尾辞のない施設も印字成分の関係を問い、結合と区切りを別の候補にする' do
    options = options_for(result_for([ 'みどり食堂', 'ひだまりテラス南' ]))
    relation = options.fetch(:relations).sole
    names = options[:options].index_by { |option| option[:value] }

    expect(options).to include(schema_version: 'store_name_options_v2', invalid: false, truncated: false)
    expect(relation).to include(
      candidate_ids: %w[page_0_line_0 page_0_line_1],
      same_name_option_ids: contain_exactly(
        names.fetch('みどり食堂ひだまりテラス南')[:option_id], names.fetch('みどり食堂 ひだまりテラス南')[:option_id]
      ),
      store_location_option_ids: [ names.fetch('みどり食堂 ひだまりテラス南')[:option_id] ]
    )
    expect(relation[:separate_option_ids]).to contain_exactly(
      names.fetch('みどり食堂')[:option_id], names.fetch('ひだまりテラス南')[:option_id]
    )
  end

  it '同じ名称の成分でも区切りを保った既存表示を選び保存往復できる' do
    options = options_for(result_for([ 'みどり 食堂', 'ひだまりテラス南' ]))
    relation = options.fetch(:relations).sole
    spaced = options[:options].find { |option| option[:value] == 'みどり 食堂 ひだまりテラス南' }
    selection = {
      decision: 'select', option_id: spaced[:option_id],
      relations: [ { relation_id: relation[:relation_id], decision: 'same_name' } ]
    }

    result = Analysis.store_name_selection(selection, options:)

    expect(result).to include(decision: 'select', option_id: spaced[:option_id])
    expect(Analysis.store_name_selection(JSON.parse(result.to_json), options:)).to eq(result)
  end

  it '名称内の印字済み空白を比較用の正規化で消さない' do
    options = options_for(result_for([ 'みどり 食堂', 'ひだまりテラス南' ]))

    expect(options[:options].map { |option| option[:value] }).to include('みどり 食堂 ひだまりテラス南')
    expect(options[:options].map { |option| option[:value] }).not_to include('みどり食堂ひだまりテラス南')
  end

  it '施設名と用途を一つの名前として選ぶ候補も残す' do
    options = options_for(result_for([ 'サンプル公園', '駐車場' ]))
    relation = options.fetch(:relations).sole
    joined = options[:options].find { |option| option[:value] == 'サンプル公園駐車場' }

    expect(relation[:same_name_option_ids]).to include(joined[:option_id])
    selection = { decision: 'select', option_id: joined[:option_id],
      relations: [ { relation_id: relation[:relation_id], decision: 'same_name' } ] }
    expect(Analysis.store_name_selection(selection, options:)).to include(decision: 'select', option_id: joined[:option_id])
  end

  it '単一行で完成している名前は表記を変更せず関係候補を作らない' do
    name = 'SampleMart 東京中央店'
    options = options_for(result_for([ name ]))

    expect(options[:options].map { |option| option[:value] }).to eq([ name ])
    expect(options[:relations]).to eq([])
  end

  context 'spanを持たないline source' do
    let(:lines) { [ 'サンプル公園', '駐車場', '領収書', '株式会社サンプル管理' ] }
    let(:input) { { lines: lines, candidates: { store_name: '株式会社サンプル管理' } } }

    it '施設と用途の候補をline identityへ結び付け、印字spanを捏造しない' do
      old = Analysis.store_name_options(ocr_result: input)
      options = options_for(input)
      joined = options[:options].find { |option| option[:value] == 'サンプル公園駐車場' }

      expect(joined).to include(candidate_ids: %w[line_0 line_1], line_indexes: [ 0, 1 ])
      relation = options[:relations].sole
      expect(relation).to include(candidate_ids: %w[line_0 line_1], same_name_option_ids: include(joined[:option_id]))
      expect(relation.values_at(:left_complete_option_ids, :right_complete_option_ids)).to eq([ [], [] ])
      expect(options.to_json).not_to include('span', 'page_index', '株式会社サンプル管理駐車場')
      expect(Analysis.store_name_options(ocr_result: input)).to eq(old)
    end

    it '明示lines pathでもmissing spanを保ったまま関係候補にする' do
      input[:candidates][:store_name_evidence] = {
        schema_version: 'store_name_evidence_v1', invalid: false, truncated: false,
        candidates: lines.each_with_index.map do |text, index|
          { candidate_id: "line_#{index}", source: 'line', source_path: "lines[#{index}]",
            line_index: index, text: text, span_state: 'missing' }
        end
      }

      options = options_for(input)

      expect(options[:options]).to include(include(value: 'サンプル公園駐車場', candidate_ids: %w[line_0 line_1]))
      expect(input[:candidates][:store_name_evidence][:candidates]).to all(include(span_state: 'missing'))
    end

    it '欠けたline positionや間の別lineを飛び越して施設用途を合成しない' do
      input[:lines] = [ 'サンプル公園', '', '駐車場', '領収書' ]

      options = options_for(input)

      expect(options[:options].pluck(:value)).not_to include('サンプル公園駐車場', 'サンプル公園 駐車場')
      expect(options[:relations]).to be_empty
    end

    it 'page metadata付きのmissing spanをlegacy lineへ格下げして合成しない' do
      input = result_for([ 'SampleMart', '中央店' ])
      input[:candidates][:store_name_evidence][:candidates].each do |entry|
        entry[:span_state] = 'missing'
        entry.except!(:span, :string_index_type)
      end

      options = options_for(input)

      expect(options[:relations]).to be_empty
      expect(options[:options].pluck(:value)).to contain_exactly('SampleMart', '中央店')
    end

    it '不正なspanやline pathをmissing spanとして救済しない' do
      input = result_for([ 'サンプル公園', '駐車場' ])
      changes = [ { span_state: 'missing' }, { string_index_type: 'unknown' }, { source_path: 'lines[99]' } ]

      changes.each do |attributes|
        malformed = input.deep_dup
        malformed[:candidates][:store_name_evidence][:candidates].first.merge!(attributes)

        expect(options_for(malformed)).to include(options: [], relations: [], invalid: true)
      end
    end

    it '連続する1文字line全体が帳票題名の場合だけ候補から除外する' do
      input = { lines: [ 'SampleMart', '中央南三丁目店', '領', '収', '証', '合 計' ],
        candidates: { store_name: '中央南三丁目店' } }
      old = Analysis.store_name_options(ocr_result: input)
      options = options_for(input)

      expect(options[:options].pluck(:value)).to include('SampleMart 中央南三丁目店')
      expect(options[:options].flat_map { |option| option[:candidate_ids] } & %w[line_2 line_3 line_4]).to be_empty
      expect(Analysis.store_name_options(ocr_result: input)).to eq(old)
    end

    it '題名に一致しない1文字名や間が空いた断片を一律に消さない' do
      input = { lines: [ '森', '領', '', '収', '証', '合 計' ], candidates: {} }

      options = options_for(input)

      expect(options[:options].pluck(:value)).to include('森', '領', '収', '証')
    end

    it '帳票断片の判定を注入されたprofileに従わせる' do
      profile = ReceiptAnalysisProfiles.default.dup
      profile.define_singleton_method(:store_document_title_pattern) { /\ADOC\z/ }
      input = { lines: [ 'D', 'O', 'C', '合 計', '領', '収', '証' ], candidates: {} }

      options = Analysis.store_name_options(ocr_result: input, version: 'store_name_options_v2', profile: profile)

      expect(options[:options].flat_map { |option| option[:candidate_ids] } & %w[line_0 line_1 line_2]).to be_empty
      expect(options[:options].pluck(:value)).to include('領', '収', '証')
    end
  end

  context '方向付きの印字済み完全名称' do
    [ false, true ].each do |reversed|
      it "別表記の完全名称を正しい側だけから選べる（逆順: #{reversed}）" do
        name = 'サンプルブランド 中央店'
        lines = [ 'Sample Brand', name ]
        lines.reverse! if reversed
        input = result_for(lines)
        old = Analysis.store_name_options(ocr_result: input)
        options = options_for(input)
        relation = options[:relations].sole
        names = options[:options].index_by { |option| option[:value] }
        complete = names.fetch(name)
        brand = names.fetch('Sample Brand')
        direction = reversed ? 'left_complete' : 'right_complete'
        opposite = reversed ? 'right_complete' : 'left_complete'

        expect(relation.fetch("#{direction}_option_ids".to_sym)).to eq([ complete[:option_id] ])
        expect(relation.fetch("#{opposite}_option_ids".to_sym)).to eq([ brand[:option_id] ])
        answer = { decision: 'select', option_id: complete[:option_id],
          relations: [ { relation_id: relation[:relation_id], decision: direction } ] }
        expect(Analysis.store_name_selection(answer, options:)[:decision]).to eq('select')
        expect(Analysis.store_name_selection(answer.merge(option_id: brand[:option_id]), options:)[:decision]).to eq('invalid')
        expect(Analysis.store_name_options(ocr_result: input)).to eq(old)
      end
    end

    it '単独line全体と一致するMerchantNameをdedup後も完全名称の方向へ結び付ける' do
      name = 'サンプルブランド 中央店'
      input = result_for([ 'Sample Brand', name ])
      input[:candidates][:store_name_evidence][:candidates] << {
        candidate_id: 'merchant_name', text: name, source: 'merchant_name',
        source_path: 'documents[0].fields.MerchantName', span_state: 'exact',
        span: { offset: 40, length: name.length }, string_index_type: 'textElements'
      }
      options = options_for(input)
      complete = options[:options].select { |option| option[:value] == name }

      expect(complete.size).to eq(1)
      expect(complete.sole).to include(candidate_ids: %w[merchant_name page_0_line_1], line_indexes: [ 1 ])
      expect(options[:relations].sole[:right_complete_option_ids]).to eq([ complete.sole[:option_id] ])
    end

    it '全文と同じ表示でも部分spanのMerchantNameを方向候補にしない' do
      name = 'サンプルブランド 中央店'
      input = result_for([ 'Sample Brand', name ])
      input[:candidates][:store_name_evidence][:candidates] << {
        candidate_id: 'merchant_name', text: name, source: 'merchant_name',
        source_path: 'documents[0].fields.MerchantName', span_state: 'exact',
        span: { offset: 40, length: name.length - 1 }, string_index_type: 'textElements'
      }
      options = options_for(input)
      complete = options[:options].find { |option| option[:candidate_ids] == [ 'page_0_line_1' ] }
      partial = options[:options].find { |option| option[:candidate_ids] == [ 'merchant_name' ] }

      expect(partial).not_to be_nil
      expect(partial[:line_indexes]).to be_empty
      expect(options[:relations].sole[:right_complete_option_ids]).to eq([ complete[:option_id] ])
      expect(options[:relations].sole[:right_complete_option_ids]).not_to include(partial[:option_id])
    end

    it '法人語除去や内部空白削除で作った表示を単独sourceと同一視しない' do
      input = result_for([ '株式会社サンプル 食堂', '中央店' ])
      evidence = input[:candidates][:store_name_evidence][:candidates]
      originals = Analysis.store_name_options(ocr_result: input)[:options]
      originals = originals.map do |option|
        next option unless option[:candidate_ids].size == 2

        option.merge(display_components: [
          { candidate_id: 'page_0_line_0', text: 'サンプル 食堂' },
          { candidate_id: 'page_0_line_1', text: '中央店' }
        ])
      end
      altered = [ 'サンプル 食堂', '株式会社サンプル食堂' ].each_with_index.map do |name, index|
        {
          option_id: "store_option_#{(index + 1).to_s * 32}", value: name,
          candidate_ids: [ 'page_0_line_0' ], source: 'line', line_indexes: [ 0 ]
        }
      end
      options = described_class.call(
        options: originals + altered, evidence: evidence, profile: ReceiptAnalysisProfiles.default, truncated: false, invalid: false
      )
      complete_ids = options[:relations].flat_map { |relation| relation.fetch(:left_complete_option_ids) }

      expect(complete_ids).not_to be_empty
      expect(complete_ids & altered.map { |option| option[:option_id] }).to be_empty
    end

    it '新しい合成候補を片側の印字済み名称へ昇格させない' do
      options = options_for(result_for([ 'みどり食堂', 'ひだまりテラス南' ]))
      relation = options[:relations].sole
      combined = relation[:same_name_option_ids] | relation[:store_location_option_ids]
      complete = relation.fetch(:left_complete_option_ids) | relation.fetch(:right_complete_option_ids)

      expect(complete.size).to eq(2)
      expect(complete & combined).to be_empty
    end

    it '大小文字だけを変更した候補も印字済み全文と同一視しない' do
      input = result_for([ 'Sample Brand', 'サンプルブランド 中央店' ])
      originals = Analysis.store_name_options(ocr_result: input)[:options]
      printed = originals.find { |option| option[:candidate_ids] == [ 'page_0_line_0' ] }
      changed = printed.merge(option_id: "store_option_#{'9' * 32}", value: 'SAMPLE BRAND')
      options = described_class.call(
        options: originals + [ changed ], evidence: input[:candidates][:store_name_evidence][:candidates],
        profile: ReceiptAnalysisProfiles.default, truncated: false, invalid: false
      )

      expect(options[:relations].sole[:left_complete_option_ids]).to eq([ printed[:option_id] ])
    end

    it '完全名称判定で別relationの支店成分を省略できない' do
      input = result_for([ 'Sample Brand', 'サンプルブランド', '中央店' ])
      options = options_for(input)
      selected = options[:options].find { |option| option[:value] == 'サンプルブランド' }
      first = options[:relations].find { |relation| relation[:candidate_ids] == %w[page_0_line_0 page_0_line_1] }
      last = options[:relations].find { |relation| relation[:candidate_ids] == %w[page_0_line_1 page_0_line_2] }
      answer = {
        decision: 'select', option_id: selected.fetch(:option_id),
        relations: [ { relation_id: first.fetch(:relation_id), decision: 'right_complete' },
          { relation_id: last.fetch(:relation_id), decision: 'store_location' } ]
      }

      expect(first.fetch(:right_complete_option_ids)).to include(selected[:option_id])
      expect(Analysis.store_name_selection(answer, options:)[:decision]).to eq('invalid')
    end
  end

  it '入力順を逆転しても同じ出典の候補と関係を再構築する' do
    input = result_for([ 'みどり食堂', 'ひだまりテラス南' ])
    options = options_for(input)
    input[:candidates][:store_name_evidence][:candidates].reverse!

    expect(options_for(input)).to eq(options)
  end

  it '同じ文字列でも異なるpageの店舗を重複として消さない' do
    input = result_for([ 'みどり食堂' ])
    second = result_for([ 'みどり食堂' ], page: 1).dig(:candidates, :store_name_evidence, :candidates).first
    second[:line_index] = 1
    input[:candidates][:store_name_evidence][:candidates] << second
    options = options_for(input)

    expect(options[:options].size).to eq(2)
    expect(options[:options].map { |option| option[:option_id] }.uniq.size).to eq(2)
    expect(options[:relations]).to eq([])
  end

  it '別pageや非連続行を同一名称の関係として提示しない' do
    input = result_for([ 'みどり食堂', 'ひだまりテラス南' ])
    last = input[:candidates][:store_name_evidence][:candidates].last
    last.merge!(candidate_id: 'page_1_line_0', source_path: 'pages[1].lines[0]', page_index: 1, provider_line_index: 0)

    expect(options_for(input)[:relations]).to eq([])
  end

  it '表示から除外した重複symbolを支持に残してブランドと支店の関係を提示する' do
    options = options_for(result_for([ 'SampleMart®', '®', '中央店' ]))
    complete = options[:options].find { |option| option[:value] == 'SampleMart® 中央店' }

    expect(options[:relations]).to include(include(
      candidate_ids: %w[page_0_line_0 page_0_line_2],
      store_location_option_ids: include(complete.fetch(:option_id))
    ))
    expect(complete[:candidate_ids]).to include('page_0_line_1')
    expect(options[:options].flat_map(&:keys)).not_to include(:display_components)
  end

  it 'MerchantNameと重複するlogo断片を表示成分へ戻さず支店との関係を提示する' do
    input = result_for([ 'サンプルストア', 'ABC XY', '中央店' ])
    input[:candidates][:store_name_evidence][:candidates] << {
      candidate_id: 'merchant_name', text: 'サンプルストア', source: 'merchant_name',
      source_path: 'documents[0].fields.MerchantName', span_state: 'exact',
      span: { offset: 0, length: 'サンプルストア'.length }, string_index_type: 'textElements'
    }
    options = options_for(input)
    complete = options[:options].find { |option| option[:value] == 'サンプルストア 中央店' }

    expect(options[:relations]).to include(include(
      candidate_ids: %w[page_0_line_0 page_0_line_2],
      store_location_option_ids: include(complete.fetch(:option_id))
    ))
    expect(complete[:candidate_ids]).to include('merchant_name', 'page_0_line_1')
  end

  it 'logoと業態と支店を構成する際にdomainを表示せず関係の支持に残す' do
    input = result_for([
      'samplecacaok', 'maitre sample suisse', 'since 1900',
      'サムプル ショコラ ブティック&カフェ', '中央店', 'www.samplecacao.jp'
    ])
    options = options_for(input)
    complete = options[:options].find { |option| option[:value] == 'Samplecacao ショコラブティック&カフェ 中央店' }

    expect(complete).not_to be_nil
    expect(options[:relations]).to include(
      include(candidate_ids: %w[page_0_line_0 page_0_line_3], store_location_option_ids: include(complete[:option_id])),
      include(candidate_ids: %w[page_0_line_3 page_0_line_4], store_location_option_ids: include(complete[:option_id]))
    )
    expect(complete[:candidate_ids]).to include('page_0_line_5')
  end

  it '3成分の各境界に対応した4つの表示を重複せず構成する' do
    input = result_for([ 'サンプルの', '食堂', '中央店' ])
    input[:candidates][:store_name_evidence][:candidates] << {
      candidate_id: 'merchant_name', text: 'サンプルの 食堂', source: 'merchant_name',
      source_path: 'documents[0].fields.MerchantName', span_state: 'exact',
      span: { offset: 0, length: 42 }, string_index_type: 'textElements'
    }
    options = options_for(input)
    full = options[:options].select { |option| option[:candidate_ids].include?('merchant_name') && option[:candidate_ids].include?('page_0_line_2') }

    expect(full.map { |option| option[:value] }).to contain_exactly(
      'サンプルの食堂中央店', 'サンプルの 食堂中央店', 'サンプルの食堂 中央店', 'サンプルの 食堂 中央店'
    )
    expect(options[:relations].map { |relation| relation[:candidate_ids] }).to contain_exactly(
      %w[page_0_line_0 page_0_line_1], %w[page_0_line_1 page_0_line_2]
    )
    first_edge = options[:relations].find { |relation| relation[:candidate_ids] == %w[page_0_line_0 page_0_line_1] }
    last_edge = options[:relations].find { |relation| relation[:candidate_ids] == %w[page_0_line_1 page_0_line_2] }
    full.each do |option|
      first_kind = option[:value].start_with?('サンプルの ') ? :store_location_option_ids : :same_name_option_ids
      last_kind = option[:value].end_with?(' 中央店') ? :store_location_option_ids : :same_name_option_ids
      expect(first_edge[first_kind]).to include(option[:option_id])
      expect(last_edge[last_kind]).to include(option[:option_id])
      selection = { decision: 'select', option_id: option[:option_id],
        relations: options[:relations].map { |relation| { relation_id: relation[:relation_id], decision: 'same_name' } } }
      expect(Analysis.store_name_selection(selection, options:)).to include(decision: 'select', option_id: option[:option_id])
    end
    expect(options[:options].map { |option| option[:option_id] }.uniq.size).to eq(options[:options].size)
  end

  it '完全に同じMerchantNameとlineの表示を一つにして根拠と全関係の参照を維持する' do
    input = result_for([ 'みどり食堂', 'ひだまりテラス南' ])
    input[:candidates][:store_name_evidence][:candidates] << {
      candidate_id: 'merchant_name', text: 'みどり食堂 ひだまりテラス南', source: 'merchant_name',
      source_path: 'documents[0].fields.MerchantName', confidence: 0.2, span_state: 'exact',
      span: { offset: 0, length: 48 }, string_index_type: 'textElements'
    }
    options = options_for(input)
    complete = options[:options].select { |option| option[:value] == 'みどり食堂 ひだまりテラス南' }

    expect(complete.size).to eq(1)
    expect(complete.sole).to include(
      source: 'merchant_name', confidence: 0.2,
      candidate_ids: %w[merchant_name page_0_line_0 page_0_line_1], line_indexes: [ 0, 1 ]
    )
    expect(options[:relations].sole[:store_location_option_ids]).to eq([ complete.sole[:option_id] ])
    input[:candidates][:store_name_evidence][:candidates].reverse!
    expect(options_for(input)).to eq(options)
  end

  it 'line群を部分包含するMerchantNameを同じ表示の完全候補へ同一化しない' do
    input = result_for([ 'みどり食堂', 'ひだまりテラス南' ])
    input[:candidates][:store_name_evidence][:candidates] << {
      candidate_id: 'merchant_name', text: 'みどり食堂 ひだまりテラス南', source: 'merchant_name',
      source_path: 'documents[0].fields.MerchantName', span_state: 'exact',
      span: { offset: 0, length: 90 }, string_index_type: 'textElements'
    }
    options = options_for(input)

    expect(options[:options]).not_to include(include(candidate_ids: [ 'merchant_name' ]))
    expect(options[:options]).to include(include(value: 'みどり食堂 ひだまりテラス南', source: 'line'))
    expect(options[:relations].sole[:store_location_option_ids]).not_to be_empty
  end

  it '同じcomponentの重複入力は展開上限を超えても一つの候補集合へまとめる' do
    input = result_for([ 'みどり食堂', 'ひだまりテラス南' ])
    source = Analysis.store_name_options(ocr_result: input)[:options]
    repeated = Array.new(30) { source }.flatten
    options = described_class.call(
      options: repeated, evidence: input[:candidates][:store_name_evidence][:candidates],
      profile: ReceiptAnalysisProfiles.default, truncated: false, invalid: false
    )

    expect(options[:invalid]).to be(false)
    expect(options[:options].map { |option| option[:option_id] }.uniq.size).to eq(options[:options].size)
  end

  it '同じ出典に異なる補正表示がある場合もoption IDを衝突させない' do
    input = result_for([ 'samplemart', '中央店' ])
    source = input[:candidates][:store_name_evidence][:candidates]
    variants = %w[SampleMart Samplemart].map.with_index do |name, index|
      {
        option_id: "store_option_#{index.to_s.rjust(32, '0')}", value: "#{name} 中央店",
        candidate_ids: source.map { |entry| entry[:candidate_id] }, source: 'line', line_indexes: [ 0, 1 ],
        display_components: [ { candidate_id: 'page_0_line_0', text: name }, { candidate_id: 'page_0_line_1', text: '中央店' } ]
      }
    end
    options = described_class.call(options: variants, evidence: source, profile: ReceiptAnalysisProfiles.default, truncated: false, invalid: false)

    expect(options[:options].size).to eq(2)
    expect(options[:options].map { |option| option[:option_id] }.uniq.size).to eq(2)
    expect(options[:relations].sole[:store_location_option_ids].size).to eq(2)
  end

  context '帳票見出しと運営法人を挟むブランドと支店' do
    def operator_result(title: '領収書', name: '中央店', extra_lines: [])
      input = result_for([ 'SAMPLEMART', title, '株式会社サンプル運営', name, *extra_lines ])
      entries = input[:candidates][:store_name_evidence][:candidates]
      entries.delete_at(1)
      entries << {
        candidate_id: 'merchant_name', text: "株式会社サンプル運営 #{name}", source: 'merchant_name',
        source_path: 'documents[0].fields.MerchantName', span_state: 'exact',
        span: { offset: 80, length: 40 + name.length }, string_index_type: 'textElements'
      }
      input
    end

    it '既存の帳票見出しだけを越えた同pageブランドと支店を関係確認の候補にする' do
      input = operator_result(title: '領 収 書')
      old = Analysis.store_name_options(ocr_result: input)
      options = options_for(input)
      complete = options[:options].find { |option| option[:value] == 'SAMPLEMART 中央店' }

      expect(complete).not_to be_nil
      expect(complete[:candidate_ids]).to contain_exactly('merchant_name', 'page_0_line_0', 'page_0_line_2', 'page_0_line_3')
      expect(options[:relations]).to include(include(
        candidate_ids: %w[page_0_line_0 page_0_line_3], store_location_option_ids: include(complete[:option_id])
      ))
      expect(old[:options]).not_to include(include(value: 'SAMPLEMART 中央店'))
      expect(Analysis.store_name_options(ocr_result: input)).to eq(old)
    end

    it '全角括弧や空白を含む複合帳票見出しもprofileの完全一致で確認する' do
      expect(options_for(operator_result(title: '納 品 書（領 収 書）'))[:options]).to include(include(value: 'SAMPLEMART 中央店'))
    end

    [ '中央店', 'ひだまりテラス南' ].each do |name|
      it "#{name}に支店接尾辞を要求せず、法人を支持情報として店舗と施設の関係だけをbindする" do
        input = operator_result(name:)
        old = Analysis.store_name_options(ocr_result: input)
        options = options_for(input)
        complete = options[:options].find { |option| option[:value] == "SAMPLEMART #{name}" }

        expect(complete).not_to be_nil
        expect(options[:relations].size).to eq(1)
        relation = options[:relations].sole
        expect(relation[:candidate_ids]).to eq(%w[page_0_line_0 page_0_line_3])
        selection = Analysis::StoreNameSelection.call(
          { decision: 'select', option_id: complete[:option_id],
            relations: [ { relation_id: relation[:relation_id], decision: 'store_location' } ] }, options:
        )

        expect(selection[:decision]).to eq('select')
        expect(options[:options]).to include(include(value: '株式会社サンプル運営'))
        expect(options[:options]).to include(include(value: "株式会社サンプル運営 #{name}"))
        expect(Analysis.store_name_options(ocr_result: input)).to eq(old)
      end
    end

    it '別ブランドがなければ従来の法人から支店への候補を変えない' do
      input = result_for([ '株式会社サンプル運営', '中央店' ])
      input[:candidates][:store_name_evidence][:candidates] << {
        candidate_id: 'merchant_name', text: '株式会社サンプル運営 中央店', source: 'merchant_name',
        source_path: 'documents[0].fields.MerchantName', span_state: 'exact',
        span: { offset: 0, length: 43 }, string_index_type: 'textElements'
      }
      options = options_for(input)

      expect(options[:options]).to include(include(value: 'サンプル運営 中央店'))
      expect(options[:relations].sole[:candidate_ids]).to eq(%w[page_0_line_0 page_0_line_1])
    end

    it '帳票見出しがない直接のブランド・法人・支店も同じexact evidenceで候補にする' do
      input = result_for([ 'SAMPLEMART', '株式会社サンプル運営', '中央店' ])
      input[:candidates][:store_name_evidence][:candidates] << {
        candidate_id: 'merchant_name', text: '株式会社サンプル運営 中央店', source: 'merchant_name',
        source_path: 'documents[0].fields.MerchantName', span_state: 'exact',
        span: { offset: 40, length: 43 }, string_index_type: 'textElements'
      }
      options = options_for(input)
      complete = options[:options].find { |option| option[:value] == 'SAMPLEMART 中央店' }

      expect(complete).not_to be_nil
      expect(options[:relations]).to include(include(
        candidate_ids: %w[page_0_line_0 page_0_line_2], store_location_option_ids: include(complete[:option_id])
      ))
    end

    {
      '別店舗' => '別の商店',
      '未知の行' => 'お知らせ',
      '帳票語を含む別名称' => '別の商店 領収書',
      '帳票見出しの後の別名称' => '領収書 サンプル',
      '帳票見出しの括弧内の別名称' => '領収書(サンプル)',
      '別名称の括弧内の帳票見出し' => 'サンプル(領収書)'
    }.each do |label, title|
      it "#{label}を帳票見出しとして読み飛ばさない" do
        expect(options_for(operator_result(title:))[:options]).not_to include(include(value: 'SAMPLEMART 中央店'))
      end
    end

    it 'profileで認めた帳票見出しだけを使用する' do
      allow(ReceiptAnalysisProfiles.default).to receive(:store_document_title_pattern).and_return(/\ADOCUMENT\z/i)

      expect(options_for(operator_result(title: 'DOCUMENT'))[:options]).to include(include(value: 'SAMPLEMART 中央店'))
      expect(options_for(operator_result)[:options]).not_to include(include(value: 'SAMPLEMART 中央店'))
    end

    it 'source行が欠けていれば候補を追加しない' do
      input = operator_result
      input[:lines] = []

      expect(options_for(input)[:options]).not_to include(include(value: 'SAMPLEMART 中央店'))
    end

    it 'source行とexact evidenceの名称が違えば候補を追加しない' do
      input = operator_result
      input[:lines] = input[:lines].dup
      input[:lines][0] = 'ChangedMart'

      expect(options_for(input)[:options]).not_to include(include(value: 'SAMPLEMART 中央店'))
    end

    it '先行ブランドが別pageなら結び付けない' do
      input = operator_result
      input[:candidates][:store_name_evidence][:candidates].first.merge!(
        candidate_id: 'page_1_line_0', source_path: 'pages[1].lines[0]', page_index: 1
      )

      expect(options_for(input)[:options]).not_to include(include(value: 'SAMPLEMART 中央店'))
    end

    it '同pageに支店が複数あれば結び付けない' do
      expect(options_for(operator_result(extra_lines: [ '西口店' ]))[:options]).not_to include(include(value: 'SAMPLEMART 中央店'))
    end

    it '同pageに別ブランドがあれば結び付けない' do
      expect(options_for(operator_result(extra_lines: [ 'OtherMart' ]))[:options]).not_to include(include(value: 'SAMPLEMART 中央店'))
    end

    it 'MerchantNameがexactでなければ結び付けない' do
      input = operator_result
      merchant = input[:candidates][:store_name_evidence][:candidates].last
      merchant.delete(:span)
      merchant.delete(:string_index_type)
      merchant[:span_state] = 'missing'

      expect(options_for(input)[:options]).not_to include(include(value: 'SAMPLEMART 中央店'))
    end

    it 'MerchantNameのspanが法人と支店を完全に覆わなければ結び付けない' do
      input = operator_result
      input[:candidates][:store_name_evidence][:candidates].last[:span][:length] += 1

      expect(options_for(input)[:options]).not_to include(include(value: 'SAMPLEMART 中央店'))
    end
  end

  it '旧版の表示とchecksumを変更しない' do
    input = result_for([ 'サンプル公園', '駐車場' ])
    old = Analysis.store_name_options(ocr_result: input, version: 'store_name_options_v1')
    options_for(input)

    expect(Analysis.store_name_options(ocr_result: input, version: 'store_name_options_v1')).to eq(old)
    expect(old[:options].map { |option| option[:value] }).not_to include('サンプル公園 駐車場')
  end
end
