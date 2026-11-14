require 'rails_helper'
require 'open3'

RSpec.describe Ai::ReceiptAnalysisSchema do
  describe '.to_json_schema' do
    subject(:schema) { described_class.to_json_schema }

    def object_schemas(node)
      case node
      when Hash
        nested = node.values.flat_map { |value| object_schemas(value) }
        node['type'] == 'object' ? [ node ] + nested : nested
      when Array
        node.flat_map { |value| object_schemas(value) }
      else
        []
      end
    end

    def enum_values(node)
      case node
      when Hash
        node.fetch('enum', []) + node.values.flat_map { |value| enum_values(value) }
      when Array
        node.flat_map { |value| enum_values(value) }
      else
        []
      end
    end

    def valid_selections(schema, selections)
      response = {
        is_receipt: true, is_receipt_confidence: nil, document_type: nil, rejection_reason: nil,
        store: { store_name_selection: nil, store_name: nil, store_address: nil, store_phone_number: nil },
        purchase: { purchased_at_text: nil }, payment: { payment_method: nil },
        items: [], receipt_adjustments: [], needs_review: false, review_reasons: []
      }
      script = <<~JS
        const fs = require('node:fs')
        const Ajv = require('ajv')
        const input = JSON.parse(fs.readFileSync(0, 'utf8'))
        const validate = new Ajv().compile(input.schema)
        const results = input.selections.map(selection => {
          input.response.store.store_name_selection = selection
          return validate(input.response)
        })
        process.stdout.write(JSON.stringify(results))
      JS
      stdout, stderr, status = Open3.capture3('node', '-e', script, stdin_data: JSON.generate(schema:, selections:, response:))
      expect(status.success?).to be(true), stderr
      JSON.parse(stdout)
    end

    it 'root objectとtop-level required keysを定義する' do
      aggregate_failures do
        expect(schema['type']).to eq('object')
        expect(schema['required']).to include(*Ai::ResponseParser::REQUIRED_KEYS)
        expect(schema['required']).to include('is_receipt_confidence')
        expect(schema['required']).to match_array(schema['properties'].keys)
      end
    end

    it 'classification keysを定義する' do
      aggregate_failures do
        expect(schema.dig('properties', 'is_receipt', 'type')).to eq('boolean')
        expect(schema.dig('properties', 'is_receipt_confidence', 'type')).to eq([ 'number', 'null' ])
        expect(schema.dig('properties', 'document_type', 'type')).to eq([ 'string', 'null' ])
        expect(schema.dig('properties', 'rejection_reason', 'enum')).to match_array(
          Ai::ResponseParser::ALLOWED_REJECTION_REASONS + [ nil ]
        )
      end
    end

    it 'rejection_reason enumがResponseParserと整合する' do
      expect(schema.dig('properties', 'rejection_reason', 'enum').compact).to match_array(
        Ai::ResponseParser::ALLOWED_REJECTION_REASONS
      )
    end

    it 'payment_method / item category / review_reasons のenumを定義する' do
      item_schema = schema.dig('properties', 'items', 'items')
      adjustment_schema = schema.dig('properties', 'receipt_adjustments', 'items')

      aggregate_failures do
        expect(schema.dig('properties', 'payment', 'properties', 'payment_method', 'enum')).to match_array(
          Receipt::PAYMENT_METHODS + [ nil ]
        )
        expect(item_schema.dig('properties', 'category', 'enum')).to eq(ReceiptItem::CATEGORIES + [ nil ])
        expect(schema.dig('properties', 'review_reasons', 'items', 'enum')).to match_array(
          Ai::ResponseParser::ALLOWED_REVIEW_REASONS
        )
        expect(adjustment_schema.dig('properties', 'review_reasons', 'items', 'enum')).to match_array(
          Ai::ResponseParser::ALLOWED_REVIEW_REASONS
        )
      end
    end

    it 'object schemaは additionalProperties false にする' do
      expect(object_schemas(schema)).to all(include('additionalProperties' => false))
    end

    it 'nullable表現を含む' do
      aggregate_failures do
        expect(schema.dig('properties', 'store', 'properties', 'store_name', 'type')).to eq([ 'string', 'null' ])
        expect(schema.dig('properties', 'items', 'items', 'properties', 'tax_rate', 'type')).to eq([ 'number', 'null' ])
      end
    end

    it '店舗名は関係の判定と候補ID選択を回答してから名称を返す' do
      store = schema.dig('properties', 'store')
      selection = store.dig('properties', 'store_name_selection')

      expect(store.fetch('properties').keys).to eq(%w[store_name_selection store_name store_address store_phone_number])
      expect(store.fetch('required')).to eq(%w[store_name_selection store_name store_address store_phone_number])

      expect(selection).to include(
        'type' => [ 'object', 'null' ],
        'additionalProperties' => false,
        'required' => %w[relations decision option_id]
      )
      expect(selection.dig('properties', 'decision', 'enum')).to eq(%w[select ambiguous reject])
      expect(selection.dig('properties', 'option_id', 'type')).to eq([ 'string', 'null' ])
      expect(selection.fetch('properties').keys).to eq(%w[relations decision option_id])
      expect(selection.dig('properties', 'option_id', 'enum')).to eq([ nil ])
      expect(selection.dig('properties', 'relations')).to eq(
        'type' => 'object', 'additionalProperties' => false, 'required' => [], 'properties' => {}
      )
    end

    it 'nilやHash以外の候補入力は候補なしのschemaへ閉じる' do
      aggregate_failures do
        expect(described_class.to_json_schema(name_options: nil)).to eq(schema)
        expect(described_class.to_json_schema(name_options: [])).to eq(schema)
      end
    end

    context '店舗名候補がある場合' do
      let(:option_id) { "store_option_#{'a' * 32}" }
      let(:relation_id) { "store_relation_#{'b' * 32}" }
      let(:name_options) do
        {
          schema_version: 'store_name_options_v2',
          options: [ { option_id: option_id, value: '候補の店舗名' } ],
          relations: [ { relation_id: relation_id } ],
          invalid: false,
          truncated: false
        }
      end
      let(:selection) do
        described_class.to_json_schema(name_options: name_options).dig('properties', 'store', 'properties', 'store_name_selection')
      end

      it '提示した候補IDと関係IDだけを許可し、名称をschemaへ複製しない' do
        original = name_options.deep_dup

        aggregate_failures do
          expect(selection.dig('properties', 'option_id', 'enum')).to eq([ option_id, nil ])
          expect(selection.dig('properties', 'relations', 'required')).to eq([ relation_id ])
          expect(selection.dig('properties', 'relations', 'properties')).to eq(
            relation_id => { 'type' => 'string', 'enum' => %w[same_name store_location left_complete right_complete unrelated ambiguous] }
          )
          expect(selection.to_json).not_to include('候補の店舗名')
          expect(name_options).to eq(original)
        end
      end

      it '5件の関係すべてをrequiredにし、省略や未知の関係を許可しない' do
        relation_ids = Array.new(5) { |index| "store_relation_#{format('%032x', index)}" }
        name_options[:relations] = relation_ids.map { |id| { relation_id: id } }
        relations = selection.dig('properties', 'relations')

        aggregate_failures do
          expect(relations).to include('type' => 'object', 'additionalProperties' => false)
          expect(relations.fetch('properties').keys).to eq(relation_ids)
          expect(relations.fetch('required')).to eq(relation_ids)
          expect(relations.fetch('properties').values).to all(eq(
            'type' => 'string', 'enum' => %w[same_name store_location left_complete right_complete unrelated ambiguous]
          ))
          expect(relations).not_to have_key('items')
        end
      end

      it '全関係の回答を要求してもnullや不確実なselectionを禁止しない' do
        aggregate_failures do
          expect(selection.fetch('type')).to eq([ 'object', 'null' ])
          expect(selection.dig('properties', 'decision', 'enum')).to eq(%w[select ambiguous reject])
          expect(selection.dig('properties', 'option_id', 'enum')).to include(nil)
          expect(selection.dig('properties', 'relations', 'required')).to eq([ relation_id ])
          expect(selection.dig('properties', 'relations', 'properties', relation_id, 'enum')).to include('ambiguous')
          expect(selection).not_to have_key('if')
        end
      end

      it '文字列keyの入力にも同じ制約を適用する' do
        symbol_schema = described_class.to_json_schema(name_options: name_options)
        string_schema = described_class.to_json_schema(name_options: name_options.deep_stringify_keys)

        expect(string_schema).to eq(symbol_schema)
      end

      it '関係がないv1候補は候補IDだけに制限する' do
        name_options[:schema_version] = 'store_name_options_v1'
        name_options.delete(:relations)

        aggregate_failures do
          expect(selection.dig('properties', 'option_id', 'enum')).to eq([ option_id, nil ])
          expect(selection.dig('properties', 'relations')).to eq(
            'type' => 'object', 'additionalProperties' => false, 'required' => [], 'properties' => {}
          )
        end
      end

      it '候補なしではnullと空の関係objectだけに制限する' do
        name_options[:options] = []
        name_options[:relations] = []

        aggregate_failures do
          expect(selection.dig('properties', 'option_id', 'enum')).to eq([ nil ])
          expect(selection.dig('properties', 'relations')).to eq(
            'type' => 'object', 'additionalProperties' => false, 'required' => [], 'properties' => {}
          )
          expect(selection.to_json).not_to include('"enum":[]')
        end
      end

      it '関係がないv2候補は空enumを作らず候補選択を維持する' do
        name_options[:relations] = []

        aggregate_failures do
          expect(selection.dig('properties', 'option_id', 'enum')).to eq([ option_id, nil ])
          expect(selection.dig('properties', 'relations')).to eq(
            'type' => 'object', 'additionalProperties' => false, 'required' => [], 'properties' => {}
          )
          expect(selection.to_json).not_to include('"enum":[]')
        end
      end

      {
        '未知version' => ->(value) { value[:schema_version] = 'unknown' },
        '未知入力key' => ->(value) { value[:unknown] = true },
        'version型不正' => ->(value) { value[:schema_version] = [] },
        'version key重複' => ->(value) { value['schema_version'] = value[:schema_version] },
        '候補配列欠損' => ->(value) { value.delete(:options) },
        '候補配列型不正' => ->(value) { value[:options] = {} },
        '候補件数超過' => ->(value) { value[:options] *= 101 },
        '候補ID重複' => ->(value) { value[:options] *= 2 },
        '候補ID形式不正' => ->(value) { value[:options][0][:option_id] = 'invented' },
        '候補ID型不正' => ->(value) { value[:options][0][:option_id] = 1 },
        '候補ID長超過' => ->(value) { value[:options][0][:option_id] = 'a' * 1_000 },
        '候補IDencoding不正' => ->(value) { value[:options][0][:option_id] = "\xFF".b.force_encoding('UTF-8') },
        '候補IDkey重複' => ->(value) { value[:options][0]['option_id'] = value[:options][0][:option_id] },
        '関係配列欠損' => ->(value) { value.delete(:relations) },
        '関係配列型不正' => ->(value) { value[:relations] = {} },
        '関係件数超過' => ->(value) { value[:relations] *= 101 },
        '関係ID重複' => ->(value) { value[:relations] *= 2 },
        '関係ID形式不正' => ->(value) { value[:relations][0][:relation_id] = 'invented' },
        '関係ID型不正' => ->(value) { value[:relations][0][:relation_id] = 1 },
        '候補なしの関係' => ->(value) { value[:options] = [] },
        'v1への関係混入' => ->(value) { value[:schema_version] = 'store_name_options_v1' },
        '不正候補' => ->(value) { value[:invalid] = true },
        '不正flagの型違い' => ->(value) { value[:invalid] = 'false' },
        '省略された候補' => ->(value) { value[:truncated] = true }
      }.each do |condition, mutate|
        it "#{condition}では自由なIDへfallbackせず候補を選択不能にする" do
          mutate.call(name_options)

          aggregate_failures do
            expect(selection.dig('properties', 'option_id', 'enum')).to eq([ nil ])
            expect(selection.dig('properties', 'relations')).to eq(
              'type' => 'object', 'additionalProperties' => false, 'required' => [], 'properties' => {}
            )
            expect(selection.to_json).not_to include('"enum":[]')
          end
        end
      end

      it '最大件数でもStructured Outputsのenum数・文字列総量上限を超えない' do
        name_options[:options] = Array.new(100) { |index| { option_id: "store_option_#{format('%032x', index)}" } }
        name_options[:relations] = Array.new(100) { |index| { relation_id: "store_relation_#{format('%032x', index)}" } }
        bounded_schema = described_class.to_json_schema(name_options: name_options)

        aggregate_failures do
          expect(selection.dig('properties', 'option_id', 'enum').size).to eq(101)
          expect(selection.dig('properties', 'relations', 'properties').size).to eq(100)
          expect(selection.dig('properties', 'relations', 'required')).to eq(
            name_options[:relations].pluck(:relation_id)
          )
          expect(enum_values(bounded_schema).size).to be <= 1_000
          expect(bounded_schema.to_json.bytesize).to be <= 120_000
        end
      end

      it '店舗選択以外のschemaと金額fieldを変更しない' do
        baseline = described_class.to_json_schema
        bounded = described_class.to_json_schema(name_options: name_options)
        baseline.dig('properties', 'store', 'properties').delete('store_name_selection')
        bounded.dig('properties', 'store', 'properties').delete('store_name_selection')

        expect(bounded).to eq(baseline)
      end
    end

    context 'v2の候補と関係の対応が揃っている場合' do
      let(:brand_id) { "store_option_#{'1' * 32}" }
      let(:partial_id) { "store_option_#{'2' * 32}" }
      let(:complete_id) { "store_option_#{'3' * 32}" }
      let(:unrelated_id) { "store_option_#{'4' * 32}" }
      let(:first_relation_id) { "store_relation_#{'1' * 32}" }
      let(:second_relation_id) { "store_relation_#{'2' * 32}" }
      let(:name_options) do
        {
          schema_version: 'store_name_options_v2', invalid: false, truncated: false,
          options: [ brand_id, partial_id, complete_id, unrelated_id ].map { |id| { option_id: id, value: '匿名の名称' } },
          relations: [
            {
              relation_id: first_relation_id, candidate_ids: %w[line_0 line_1],
              same_name_option_ids: [ complete_id ], store_location_option_ids: [ complete_id ],
              separate_option_ids: [ brand_id, partial_id ], left_complete_option_ids: [ brand_id ], right_complete_option_ids: []
            },
            {
              relation_id: second_relation_id, candidate_ids: %w[line_1 line_2],
              same_name_option_ids: [ partial_id, complete_id ], store_location_option_ids: [ partial_id, complete_id ],
              separate_option_ids: [], left_complete_option_ids: [], right_complete_option_ids: []
            }
          ]
        }
      end
      let(:bounded_schema) { described_class.to_json_schema(name_options: name_options) }

      def selection_for(id, first: 'store_location', second: 'store_location', decision: 'select')
        { relations: { first_relation_id => first, second_relation_id => second }, decision: decision, option_id: id }
      end

      it '関係が要求する名称成分を欠いたIDを拒否し、完全な候補を許可する' do
        expect(valid_selections(bounded_schema, [ selection_for(partial_id), selection_for(complete_id) ])).to eq([ false, true ])
      end

      it '同じ候補に対応する複数の関係分類を許可する' do
        answers = [ selection_for(complete_id, first: 'same_name'), selection_for(complete_id),
          selection_for(brand_id, first: 'left_complete'), selection_for(brand_id, first: 'unrelated') ]

        expect(valid_selections(bounded_schema, answers)).to eq([ true, true, true, true ])
      end

      it '右側の完全名称は右側指定と無関係を許可し、逆方向や合成候補を拒否する' do
        name_options[:relations] = [ name_options[:relations].first.merge(
          left_complete_option_ids: [], right_complete_option_ids: [ partial_id ]
        ) ]
        answers = [ [ partial_id, 'right_complete' ], [ partial_id, 'unrelated' ],
          [ partial_id, 'left_complete' ], [ complete_id, 'right_complete' ] ].map do |id, decision|
          { relations: { first_relation_id => decision }, decision: 'select', option_id: id }
        end

        expect(valid_selections(bounded_schema, answers)).to eq([ true, true, false, false ])
      end

      it '選択と関わらない関係の曖昧さを別店舗へ波及させない' do
        expect(valid_selections(bounded_schema, [ selection_for(unrelated_id, first: 'ambiguous', second: 'ambiguous') ])).to eq([ true ])
      end

      it 'nullと未選択の判断を維持し、選択時の曖昧な関係は拒否する' do
        answers = [ nil, selection_for(nil, decision: 'ambiguous'), selection_for(nil, decision: 'reject'),
          selection_for(complete_id, first: 'ambiguous'), selection_for(nil), selection_for(complete_id, decision: 'reject') ]

        expect(valid_selections(bounded_schema, answers)).to eq([ true, true, true, false, false, false ])
      end

      it '未知ID・欠損した回答・未知の関係keyを許可しない' do
        missing = selection_for(complete_id)
        missing[:relations].delete(first_relation_id)
        unknown = selection_for(complete_id)
        unknown[:relations]['unknown'] = 'unrelated'

        expect(valid_selections(bounded_schema, [ selection_for('unknown'), missing, unknown ])).to eq([ false, false, false ])
      end

      it '入力を変更せず、名称をschemaへ複製しない' do
        original = name_options.deep_dup

        aggregate_failures do
          expect(bounded_schema.to_json).not_to include('匿名の名称')
          expect(name_options).to eq(original)
          expect(described_class.to_json_schema(name_options: name_options.deep_stringify_keys)).to eq(bounded_schema)
        end
      end

      it '全branchで関係・判定・IDの回答順とstrict object契約を維持する' do
        selection = bounded_schema.dig('properties', 'store', 'properties', 'store_name_selection')
        branches = selection.fetch('anyOf').select { |entry| entry['type'] == 'object' }

        aggregate_failures do
          expect(branches).not_to be_empty
          expect(branches.map { |entry| entry.fetch('properties').keys }).to all(eq(%w[relations decision option_id]))
          expect(object_schemas(bounded_schema)).to all(include('additionalProperties' => false))
          expect(object_schemas(bounded_schema)).to all(satisfy { |entry| entry['required'].sort == entry['properties'].keys.sort })
        end
      end

      it '対応表が不完全なら既存ID制約を維持し、関係を推測しない' do
        name_options[:relations][0].delete(:separate_option_ids)
        incomplete = described_class.to_json_schema(name_options: name_options)
        name_options[:relations].each { |relation| relation.slice!(:relation_id) }

        expect(incomplete).to eq(described_class.to_json_schema(name_options: name_options))
      end

      it '対応表の型違い・未知ID・重複keyを既存制約へ戻す' do
        baseline = name_options.deep_dup
        baseline[:relations].each { |relation| relation.slice!(:relation_id) }
        expected = described_class.to_json_schema(name_options: baseline)
        mutations = [
          ->(entry) { entry[:same_name_option_ids] = nil },
          ->(entry) { entry[:same_name_option_ids] = [ 'unknown' ] },
          ->(entry) { entry['same_name_option_ids'] = entry[:same_name_option_ids] }
        ]

        mutations.each do |mutate|
          input = name_options.deep_dup
          mutate.call(input[:relations].first)
          expect(described_class.to_json_schema(name_options: input)).to eq(expected)
        end
      end

      it '店舗選択以外のschemaを維持する' do
        baseline = described_class.to_json_schema
        constrained = bounded_schema.deep_dup
        [ baseline, constrained ].each { |value| value.dig('properties', 'store', 'properties').delete('store_name_selection') }
        constrained.delete('$defs')

        expect(constrained).to eq(baseline)
      end

      it '関係制約が同じ候補をまとめても候補IDを欠落させない' do
        name_options[:options] = Array.new(100) { |index| { option_id: "store_option_#{format('%032x', index)}" } }
        ids = name_options[:options].pluck(:option_id)
        name_options[:relations] = [ name_options[:relations].first.merge(
          same_name_option_ids: ids, store_location_option_ids: ids,
          separate_option_ids: [], left_complete_option_ids: [], right_complete_option_ids: []
        ) ]
        selection = bounded_schema.dig('properties', 'store', 'properties', 'store_name_selection')
        selecting = selection.fetch('anyOf').select { |entry| entry.dig('properties', 'decision', 'enum') == [ 'select' ] }

        aggregate_failures do
          expect(selecting.size).to eq(1)
          expect(selecting.first.dig('properties', 'option_id', 'enum')).to eq(ids)
          expect(enum_values(bounded_schema).size).to be <= 1_000
          expect(bounded_schema.to_json.bytesize).to be <= 120_000
        end
      end

      it '最大件数の分岐がschema上限を超える場合は全候補を保つ既存制約へ戻す' do
        name_options[:options] = Array.new(100) { |index| { option_id: "store_option_#{format('%032x', index)}" } }
        ids = name_options[:options].pluck(:option_id)
        name_options[:relations] = Array.new(100) do |index|
          {
            relation_id: "store_relation_#{format('%032x', index)}", candidate_ids: [ "line_#{index}", "line_#{index + 1}" ],
            same_name_option_ids: [ ids[index] ], store_location_option_ids: [],
            separate_option_ids: [ ids[(index + 1) % ids.size] ], left_complete_option_ids: [], right_complete_option_ids: []
          }
        end
        baseline = name_options.deep_dup
        baseline[:relations].each { |relation| relation.slice!(:relation_id) }

        aggregate_failures do
          expect(bounded_schema).to eq(described_class.to_json_schema(name_options: baseline))
          expect(bounded_schema.dig('properties', 'store', 'properties', 'store_name_selection', 'properties', 'option_id', 'enum')).to eq(ids + [ nil ])
          expect(enum_values(bounded_schema).size).to be <= 1_000
          expect(bounded_schema.to_json.bytesize).to be <= 120_000
        end
      end
    end

    it '調整行金額maximumはdefaultの金額上限を使う' do
      expect(schema.dig('properties', 'receipt_adjustments', 'items', 'properties', 'amount', 'maximum')).to eq(999_999_999)
    end

    it '調整行金額maximumはSystemSettingsの金額上限に追従する' do
      create(:system_setting, key: 'limits.receipt_adjustment_amount_max', value: SystemSettings.stored_value(1_500))

      expect(schema.dig('properties', 'receipt_adjustments', 'items', 'properties', 'amount', 'maximum')).to eq(1_500)
    end

    it 'reference pricingのnumeric/source fieldsとcandidate選択をAI output schemaへ追加しない' do
      item_properties = schema.dig('properties', 'items', 'items', 'properties')
      prohibited_keys = %w[
        reference_pricing_candidate_id
        selected_reference_pricing_candidate_id
        candidate_id
        reference_price
        reference_price_amount
        reference_quantity
        purchased_quantity
        unit_raw
        reference_unit_code
        reference_unit_raw
        reference_price_tax_inclusion
        tax_inclusion_evidence
        pricing_source_kind
        printed_line_total
        source_text
        evidence
        corroboration
      ]

      aggregate_failures do
        expect(schema.fetch('properties')).not_to have_key('reference_pricing_candidates')
        expect(schema.fetch('properties')).not_to have_key('selected_reference_pricing_candidate_id')
        expect(schema.fetch('properties')).not_to have_key('selected_reference_pricing_candidate_ids')
        expect(item_properties.keys & prohibited_keys).to be_empty
        expect(schema.dig('properties', 'items', 'items', 'additionalProperties')).to be(false)
      end
    end
  end
end
