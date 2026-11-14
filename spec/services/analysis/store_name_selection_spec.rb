require 'rails_helper'

RSpec.describe Analysis::StoreNameSelection do
  let(:options) do
    {
      checksum: 'a' * 64,
      options: [ { option_id: 'store_option_0123456789abcdef0123456789abcdef' } ]
    }
  end

  describe '.call' do
    it '旧結果の選択欠損と、新しい候補集合に対する未選択を区別する' do
      expect(described_class.call(nil)).to be_nil
      expect(described_class.call(nil, options: options)).to eq(
        decision: 'invalid', options_checksum: 'a' * 64
      )
    end

    it '実在するoptionだけを現在の候補集合へbindする' do
      result = described_class.call(
        { decision: 'select', option_id: 'store_option_0123456789abcdef0123456789abcdef' }, options: options
      )

      expect(result).to eq(
        decision: 'select', option_id: 'store_option_0123456789abcdef0123456789abcdef', options_checksum: 'a' * 64
      )
      expect(described_class.call(result, options: options)).to eq(result)
    end

    it 'rejectとambiguousにoptionを持たせない' do
      %w[reject ambiguous].each do |decision|
        expect(described_class.call({ decision: decision, option_id: nil }, options: options)).to eq(
          decision: decision, options_checksum: 'a' * 64
        )
        expect(described_class.call({ decision: decision, option_id: 'store_option_0123456789abcdef0123456789abcdef' })).to eq(decision: 'invalid')
      end
    end

    it '未知IDと古い候補集合への選択を採用しない' do
      [
        { decision: 'select', option_id: 'store_option_1123456789abcdef0123456789abcdef' },
        { decision: 'select', option_id: 'store_option_0123456789abcdef0123456789abcdef', options_checksum: 'b' * 64 }
      ].each do |selection|
        expect(described_class.call(selection, options: options)).to eq(
          decision: 'invalid', options_checksum: 'a' * 64
        )
      end
    end

    it '不正な型・未知キー・長大値をraw値なしで拒否する' do
      [
        [], 'private text', { decision: 'unknown' },
        { decision: 'select', option_id: 'x' * 101 },
        { decision: 'select', option_id: "store_option_0\n" },
        { decision: 'select', option_id: 'store_option_0', raw_text: 'private text' },
        { decision: 'select', option_id: 'store_option_0', options_checksum: 'secret' }
      ].each do |selection|
        expect(described_class.call(selection)).to eq(decision: 'invalid')
      end
    end

    it '入力を変更せず、文字列keyの保存結果も同じ意味へ戻す' do
      selection = { 'decision' => 'select', 'option_id' => 'store_option_0123456789abcdef0123456789abcdef' }.freeze
      result = described_class.call(selection, options: options)

      expect(selection.keys).to eq(%w[decision option_id])
      expect(described_class.call(JSON.parse(result.to_json))).to eq(result)
    end

    context '候補集合のversionを保持する場合' do
      let(:versioned_options) { options.merge(schema_version: 'store_name_options_v1').freeze }
      let(:selection) do
        { decision: 'select', option_id: 'store_option_0123456789abcdef0123456789abcdef' }.freeze
      end

      it '実際に提示した候補集合のversionをbindして保存往復でも維持する' do
        result = described_class.call(selection, options: versioned_options)

        expect(result).to eq(
          decision: 'select', option_id: 'store_option_0123456789abcdef0123456789abcdef',
          options_checksum: 'a' * 64, options_schema_version: 'store_name_options_v1'
        )
        expect(described_class.call(JSON.parse(result.to_json))).to eq(result)
        expect(described_class.call(result, options: versioned_options.deep_stringify_keys)).to eq(result)
        expect(selection.keys).to eq(%i[decision option_id])
      end

      it '同じversionの保存済み選択だけを再bindする' do
        stored = selection.merge(options_schema_version: 'store_name_options_v1', options_checksum: 'a' * 64)

        expect(described_class.call(stored, options: versioned_options)).to eq(stored)
        expect(described_class.call(stored, options: options)).to eq(decision: 'invalid', options_checksum: 'a' * 64)
      end

      it '未知または不正な保存versionを現在の選択へ読み替えない' do
        [ 'store_name_options_v3', 'x' * 65, nil, false, 1, [], "\xFF".b ].each do |version|
          stored = selection.merge(options_schema_version: version)

          expect(described_class.call(stored)).to eq(decision: 'invalid')
          expect(described_class.call(stored, options: versioned_options)).to eq(
            decision: 'invalid', options_checksum: 'a' * 64, options_schema_version: 'store_name_options_v1'
          )
        end
      end

      it '未知または不正な候補集合versionでは選択を採用しない' do
        [ 'store_name_options_v3', nil, false, [], "\xFF".b ].each do |version|
          expect(described_class.call(selection, options: options.merge(schema_version: version))).to eq(
            decision: 'invalid', options_checksum: 'a' * 64
          )
        end
      end

      it '選択拒否後も検証した候補集合のversionとchecksumを残す' do
        [
          nil,
          selection.merge(option_id: 'store_option_1123456789abcdef0123456789abcdef'),
          selection.merge(options_checksum: 'b' * 64)
        ].each do |stored|
          expect(described_class.call(stored, options: versioned_options)).to eq(
            decision: 'invalid', options_checksum: 'a' * 64, options_schema_version: 'store_name_options_v1'
          )
        end
      end
    end

    context '名称成分の関係を提示した候補集合の場合' do
      let(:base_id) { 'store_option_' + '1' * 32 }
      let(:joined_id) { 'store_option_' + '2' * 32 }
      let(:location_id) { 'store_option_' + '3' * 32 }
      let(:other_id) { 'store_option_' + '4' * 32 }
      let(:right_id) { 'store_option_' + '5' * 32 }
      let(:relation_id) { 'store_relation_' + '1' * 32 }
      let(:relation) do
        {
          relation_id: relation_id,
          candidate_ids: %w[page_0_line_1 page_0_line_2],
          same_name_option_ids: [ joined_id, location_id ],
          store_location_option_ids: [ location_id ],
          separate_option_ids: [ base_id, right_id ],
          left_complete_option_ids: [ base_id ],
          right_complete_option_ids: [ right_id ]
        }
      end
      let(:relation_options) do
        {
          schema_version: 'store_name_options_v2', checksum: 'b' * 64,
          options: [ base_id, joined_id, location_id, other_id, right_id ].map { |id| { option_id: id } },
          relations: [ relation ]
        }
      end
      let(:selection) do
        {
          decision: 'select', option_id: location_id,
          relations: [ { relation_id: relation_id, decision: 'store_location' } ]
        }
      end
      let(:invalid_result) do
        { decision: 'invalid', options_checksum: 'b' * 64, options_schema_version: 'store_name_options_v2' }
      end

      it '店舗と支店の関係に対応した表示候補をbindし保存往復で保持する' do
        result = described_class.call(selection, options: relation_options)

        expect(result).to eq(selection.merge(options_checksum: 'b' * 64, options_schema_version: 'store_name_options_v2'))
        expect(described_class.call(JSON.parse(result.to_json))).to eq(result)
        expect(described_class.call(result, options: relation_options.deep_stringify_keys)).to eq(result)
        expect(selection).not_to have_key(:options_checksum)
      end

      it '一つの名称の継続と判定した場合は許可された連結候補を採用する' do
        value = selection.merge(option_id: joined_id, relations: [ { relation_id: relation_id, decision: 'same_name' } ])

        expect(described_class.call(value, options: relation_options)).to include(decision: 'select', option_id: joined_id)
      end

      it '一つの名称でも許可された区切り付き表示を採用する' do
        value = selection.merge(relations: [ { relation_id: relation_id, decision: 'same_name' } ])

        expect(described_class.call(value, options: relation_options)).to include(decision: 'select', option_id: location_id)
      end

      it '保存済みの関係で許可されていない区切り付き表示を新しい解釈で救済しない' do
        previous_relation = relation.merge(same_name_option_ids: [ joined_id ])
        value = selection.merge(relations: [ { relation_id: relation_id, decision: 'same_name' } ])

        expect(described_class.call(value, options: relation_options.merge(relations: [ previous_relation ]))).to eq(invalid_result)
      end

      it '別の名称と判定した成分を結合せず元の店舗候補を維持する' do
        value = selection.merge(option_id: base_id, relations: [ { relation_id: relation_id, decision: 'unrelated' } ])

        expect(described_class.call(value, options: relation_options)).to include(decision: 'select', option_id: base_id)
      end

      { 'left_complete' => :base_id, 'right_complete' => :right_id }.each do |decision, chosen_id|
        it "#{decision}は指定側の既存の完成名候補だけを選択し保存往復で維持する" do
          value = selection.merge(option_id: public_send(chosen_id), relations: [ { relation_id: relation_id, decision: decision } ])
          result = described_class.call(value, options: relation_options)

          expect(result).to eq(value.merge(options_checksum: 'b' * 64, options_schema_version: 'store_name_options_v2'))
          expect(described_class.call(JSON.parse(result.to_json), options: relation_options)).to eq(result)
        end
      end

      {
        '支店を認めながらブランドだけを選ぶ' => [ 'store_location', :base_id ],
        '支店の境界を認めながら区切りなしの候補を選ぶ' => [ 'store_location', :joined_id ],
        '無関係な成分を結合する' => [ 'unrelated', :location_id ],
        '関係が不明な名称を確定する' => [ 'ambiguous', :base_id ],
        '左の完成名と判定して右側を選ぶ' => [ 'left_complete', :right_id ],
        '右の完成名と判定して左側を選ぶ' => [ 'right_complete', :base_id ],
        '完成名と判定しながら新しい結合候補を選ぶ' => [ 'left_complete', :joined_id ]
      }.each do |label, (decision, chosen_id)|
        it "#{label}結果を拒否する" do
          value = selection.merge(option_id: public_send(chosen_id), relations: [ { relation_id: relation_id, decision: decision } ])

          expect(described_class.call(value, options: relation_options)).to eq(invalid_result)
        end
      end

      it '選択した店舗と関係しない成分の曖昧さだけではその店舗を棄却しない' do
        value = selection.merge(option_id: other_id, relations: [ { relation_id: relation_id, decision: 'ambiguous' } ])

        expect(described_class.call(value, options: relation_options)).to include(decision: 'select', option_id: other_id)
      end

      it '関係回答の欠損を正常な選択へ補わない' do
        expect(described_class.call(selection.except(:relations), options: relation_options)).to eq(invalid_result)
        expect(described_class.call(selection.merge(relations: []), options: relation_options)).to eq(invalid_result)
      end

      it '関係回答の一部だけで選択を採用しない' do
        second = relation.merge(relation_id: 'store_relation_' + '2' * 32)

        expect(described_class.call(selection, options: relation_options.merge(relations: [ relation, second ]))).to eq(invalid_result)
      end

      it '片側の完成名でも別関係の支店要件を免除しない' do
        second_id = 'store_relation_' + '2' * 32
        second = relation.merge(relation_id: second_id, candidate_ids: %w[page_0_line_1 page_0_line_3])
        value = selection.merge(
          option_id: base_id,
          relations: [
            { relation_id: relation_id, decision: 'left_complete' },
            { relation_id: second_id, decision: 'store_location' }
          ]
        )

        expect(described_class.call(value, options: relation_options.merge(relations: [ relation, second ]))).to eq(invalid_result)
      end

      context '完成名から別表記を経由する関係がある場合' do
        let(:second_id) { 'store_relation_' + '2' * 32 }
        let(:second_relation) do
          relation.merge(
            relation_id: second_id, candidate_ids: %w[page_0_line_2 page_0_line_3],
            separate_option_ids: [ right_id, other_id ],
            left_complete_option_ids: [ right_id ], right_complete_option_ids: [ other_id ]
          )
        end
        let(:linked_options) { relation_options.merge(relations: [ relation, second_relation ]) }
        let(:linked_selection) do
          selection.merge(
            option_id: base_id,
            relations: [
              { relation_id: relation_id, decision: 'left_complete' },
              { relation_id: second_id, decision: 'store_location' }
            ]
          )
        end

        %w[same_name store_location ambiguous].each do |decision|
          it "別表記側に必要な#{decision}関係を選択候補の非参加で無視しない" do
            linked_selection[:relations].last[:decision] = decision

            expect(described_class.call(linked_selection, options: linked_options)).to eq(invalid_result)
          end
        end

        it '右側が完成名の場合も左の別表記に必要な支店を欠落させない' do
          reversed = relation.merge(
            candidate_ids: relation[:candidate_ids].reverse,
            left_complete_option_ids: [ right_id ], right_complete_option_ids: [ base_id ]
          )
          linked_selection[:relations].first[:decision] = 'right_complete'

          expect(described_class.call(linked_selection, options: linked_options.merge(relations: [ reversed, second_relation ]))).to eq(invalid_result)
        end

        it '方向が一貫する完成名の連鎖は保存往復でも維持する' do
          linked_selection[:relations].last[:decision] = 'left_complete'
          result = described_class.call(linked_selection, options: linked_options)

          expect(result).to eq(linked_selection.merge(options_checksum: 'b' * 64, options_schema_version: 'store_name_options_v2'))
          expect(described_class.call(JSON.parse(result.to_json), options: linked_options)).to eq(result)
        end

        it '別表記よりさらに別の側が完成名とされた場合は逆向きに辿らない' do
          linked_selection[:relations].last[:decision] = 'right_complete'

          expect(described_class.call(linked_selection, options: linked_options)).to eq(invalid_result)
        end

        it '別表記側に適格な完成名候補がないcomplete回答を辿らない' do
          unqualified = second_relation.merge(left_complete_option_ids: [])
          linked_selection[:relations].last[:decision] = 'left_complete'

          expect(described_class.call(linked_selection, options: linked_options.merge(relations: [ relation, unqualified ]))).to eq(invalid_result)
        end

        it '推移した別表記に必要な支店を無視しない' do
          third_id = 'store_relation_' + '3' * 32
          third = second_relation.merge(
            relation_id: third_id, candidate_ids: %w[page_0_line_3 page_0_line_4],
            separate_option_ids: [ other_id ], left_complete_option_ids: [ other_id ], right_complete_option_ids: []
          )
          linked_selection[:relations].last[:decision] = 'left_complete'
          linked_selection[:relations] << { relation_id: third_id, decision: 'store_location' }

          expect(described_class.call(linked_selection, options: linked_options.merge(relations: [ relation, second_relation, third ]))).to eq(invalid_result)
        end

        it '別表記と別店舗が無関係ならその店舗を選択範囲へ取り込まない' do
          linked_selection[:relations].last[:decision] = 'unrelated'

          expect(described_class.call(linked_selection, options: linked_options)).to include(decision: 'select', option_id: base_id)
        end

        it '遠い独立した店舗の曖昧さを選択した店舗へ波及させない' do
          separate = second_relation.merge(candidate_ids: %w[page_0_line_10 page_0_line_11])
          linked_selection[:relations].last[:decision] = 'ambiguous'

          expect(described_class.call(linked_selection, options: linked_options.merge(relations: [ relation, separate ]))).to include(decision: 'select', option_id: base_id)
        end

        it '同店舗として到達した別表記間を無関係とする矛盾を拒否する' do
          third_id = 'store_relation_' + '3' * 32
          contradictory = second_relation.merge(relation_id: third_id)
          linked_selection[:relations].last[:decision] = 'left_complete'
          linked_selection[:relations] << { relation_id: third_id, decision: 'unrelated' }

          expect(described_class.call(linked_selection, options: linked_options.merge(relations: [ relation, second_relation, contradictory ]))).to eq(invalid_result)
        end
      end

      it '未知の関係IDと重複回答を拒否する' do
        unknown = { relation_id: 'store_relation_' + '2' * 32, decision: 'store_location' }

        expect(described_class.call(selection.merge(relations: [ unknown ]), options: relation_options)).to eq(invalid_result)
        expect(described_class.call(selection.merge(relations: selection[:relations] * 2), options: relation_options)).to eq(invalid_result)
      end

      it '不正な関係回答の型・field・enum・件数をraw値なしで拒否する' do
        answer = selection[:relations].first
        [
          nil, {}, 'private text', [ nil ],
          [ answer.merge(decision: 'guess') ],
          [ answer.merge(relation_id: "store_relation_\n") ],
          [ answer.merge(raw_text: 'private text') ],
          [ answer.merge('decision' => 'same_name') ],
          Array.new(101) { |index| { relation_id: "store_relation_#{index.to_s(16).rjust(32, '0')}", decision: 'unrelated' } }
        ].each do |answers|
          expect(described_class.call(selection.merge(relations: answers), options: relation_options)).to eq(invalid_result)
        end
      end

      it '提示側の関係欠損・不正形状・重複・過多を拒否する' do
        [
          nil, {}, [ relation.except(:candidate_ids) ], [ relation.merge(raw_text: 'private text') ], [ relation ] * 2,
          Array.new(101) { |index| relation.merge(relation_id: "store_relation_#{index.to_s(16).rjust(32, '0')}") }
        ].each do |relations|
          expect(described_class.call(selection, options: relation_options.merge(relations: relations))).to eq(invalid_result)
        end
      end

      it '提示していないoptionや不正な成分IDへの関係を拒否する' do
        [
          relation.merge(store_location_option_ids: [ 'store_option_' + 'f' * 32 ]),
          relation.merge(candidate_ids: [ 'private text', 'page_0_line_2' ]),
          relation.merge(candidate_ids: %w[page_0_line_1 page_0_line_1]),
          relation.merge(candidate_ids: %w[page_0_line_1]),
          relation.merge(store_location_option_ids: [ location_id, location_id ]),
          relation.merge(separate_option_ids: [ location_id ]),
          relation.merge(left_complete_option_ids: [ 'store_option_' + 'f' * 32 ]),
          relation.merge(left_complete_option_ids: [ joined_id ]),
          relation.merge(right_complete_option_ids: [ base_id ])
        ].each do |invalid_relation|
          expect(described_class.call(selection, options: relation_options.merge(relations: [ invalid_relation ]))).to eq(invalid_result)
        end
      end

      it '結合形式が同じ表示になる関係では同一optionの参照を許可する' do
        same_display = relation.merge(same_name_option_ids: [ location_id ])

        expect(described_class.call(selection, options: relation_options.merge(relations: [ same_display ]))).to include(decision: 'select')
      end

      it '関係のない単純な候補集合では回答欠損を空配列として保存できる' do
        result = described_class.call(selection.except(:relations), options: relation_options.merge(relations: []))

        expect(result).to include(decision: 'select', relations: [], options_schema_version: 'store_name_options_v2')
      end

      it 'rejectとambiguousの未確定結果に完全な関係回答を要求しない' do
        %w[reject ambiguous].each do |decision|
          expect(described_class.call({ decision: decision }, options: relation_options)).to include(decision: decision)
        end
      end

      it '拒否結果を保存し再bindしても有効な選択へ変わらない' do
        result = described_class.call(selection.except(:relations), options: relation_options)

        expect(result).to eq(invalid_result)
        expect(described_class.call(JSON.parse(result.to_json), options: relation_options)).to eq(result)
      end

      it '旧versionへ関係回答を付けて新契約と読み替えない' do
        old_options = relation_options.merge(schema_version: 'store_name_options_v1').except(:relations)
        expected = { decision: 'invalid', options_checksum: 'b' * 64, options_schema_version: 'store_name_options_v1' }

        expect(described_class.call(selection, options: old_options)).to eq(expected)
        expect(described_class.call(selection.merge(options_schema_version: 'store_name_options_v1'))).to eq(decision: 'invalid')
        expect(described_class.call(selection.except(:relations).merge(relations: []), options: old_options)).to eq(
          decision: 'select', option_id: location_id, options_checksum: 'b' * 64, options_schema_version: 'store_name_options_v1'
        )
      end

      it '保存版と提示版の不一致をchecksumが同じでも拒否する' do
        stored = selection.merge(options_schema_version: 'store_name_options_v1')

        expect(described_class.call(stored, options: relation_options)).to eq(invalid_result)
      end
    end
  end
end
