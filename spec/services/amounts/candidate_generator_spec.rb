require 'rails_helper'

RSpec.describe Amounts::CandidateGenerator do
  def generate(receipt: {}, items: [], tax_details: [], adjustments: [], payments: [], context: :analysis, tax_rounding_modes: [ :floor ], discount_rounding_modes: [ :round ], tax_excluded_price_conversion_enabled: true)
    described_class.new(
      receipt: receipt,
      items: items,
      tax_details: tax_details,
      adjustments: adjustments,
      payments: payments,
      context: context,
      tax_rounding_modes: tax_rounding_modes,
      discount_rounding_modes: discount_rounding_modes,
      tax_excluded_price_conversion_enabled: tax_excluded_price_conversion_enabled
    ).call
  end

  def reference_item(amount:, tax_inclusion:, **overrides)
    {
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: amount,
      reference_quantity: 1,
      reference_quantity_unit_code: 'each',
      reference_quantity_unit_raw: nil,
      reference_price_tax_inclusion: tax_inclusion,
      quantity: 1,
      quantity_unit_code: 'each',
      quantity_unit_raw: nil,
      price: 999,
      line_total: 777,
      tax_rate: BigDecimal('0.10')
    }.merge(overrides)
  end

  def explicit_item_with_reference_diagnostic(line_total:, tax_inclusion:)
    {
      pricing_source_kind: 'explicit_line_total',
      reference_price_amount: 100,
      reference_quantity: 3,
      reference_quantity_unit_code: 'each',
      reference_quantity_unit_raw: nil,
      reference_price_tax_inclusion: tax_inclusion,
      quantity: 1,
      quantity_unit_code: 'each',
      quantity_unit_raw: nil,
      price: nil,
      original_line_total: line_total,
      line_total: line_total,
      tax_rate: BigDecimal('0.10')
    }
  end

  it 'generates candidates for each discount rounding mode' do
    candidates = generate(
      items: [
        {
          price: 271,
          quantity: 1,
          quantity_unit_code: 'each',
          line_total: nil,
          discount_rate: BigDecimal('0.5'),
          tax_rate: BigDecimal('0')
        }
      ],
      discount_rounding_modes: %i[floor round ceil]
    )

    included = candidates.select do |candidate|
      candidate.basis == 'items_as_tax_included' && candidate.rounding_scope == :per_item
    end
    by_discount_rounding = included.index_by { |candidate| candidate.calculation_profile[:discount_rounding_mode] }

    aggregate_failures do
      # 検算: 271円の50%引き。floorは割引135円で残額136円、round/ceilは割引136円で残額135円。
      expect(by_discount_rounding.keys).to contain_exactly(:floor, :round, :ceil)
      expect(by_discount_rounding[:floor].purchase_total).to eq(136)
      expect(by_discount_rounding[:floor].computed_items.first[:discount_amount]).to eq(135)
      expect(by_discount_rounding[:round].purchase_total).to eq(135)
      expect(by_discount_rounding[:round].computed_items.first[:discount_amount]).to eq(136)
      expect(by_discount_rounding[:ceil].purchase_total).to eq(135)
      expect(by_discount_rounding[:ceil].computed_items.first[:discount_amount]).to eq(136)
    end
  end

  describe 'reference price tax projection' do
    it 'explicit authorityをdiagnostic referenceの税区分から再分類・税投影しない' do
      aggregate_failures do
        %w[gross net].product([ 33, 34, 35 ]).each do |tax_inclusion, line_total|
          candidates = generate(
            items: [
              explicit_item_with_reference_diagnostic(
                line_total: line_total,
                tax_inclusion: tax_inclusion
              )
            ],
            context: :analysis
          )
          item_candidates = candidates.select { |candidate| candidate.basis.start_with?('items_as_') }
          label = "#{tax_inclusion}:#{line_total}"

          expect(item_candidates).not_to be_empty, label
          expect(item_candidates.map { |candidate| candidate.computed_items.first[:line_total] })
            .to all(eq(line_total)), label
          expect(item_candidates.map { |candidate| candidate.computed_items.first[:original_line_total] })
            .to all(eq(line_total)), label
          expect(item_candidates.map { |candidate| candidate.computed_items.first[:price] })
            .to all(be_nil), label
          expect(item_candidates.map { |candidate| candidate.computed_items.first[:reference_price_tax_inclusion] })
            .to all(eq(tax_inclusion)), label
          expect(item_candidates.map { |candidate| candidate.calculation_profile[:item_amount_basis] }.compact)
            .to all(eq(:line_total_as_recorded)), label
        end
      end
    end

    it 'explicit/count authorityの割引後totalをlegacy discounted-original候補で割引前へ戻さない' do
      explicit_item = explicit_item_with_reference_diagnostic(line_total: 90, tax_inclusion: 'gross').merge(
        reference_price_amount: 100,
        reference_quantity: 1,
        original_line_total: 100,
        discount_amount: 10,
        discount_rate: BigDecimal('0.1')
      )
      count_item = {
        pricing_source_kind: 'count_unit_price',
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        quantity_unit_raw: nil,
        original_line_total: 100,
        discount_amount: 10,
        discount_rate: BigDecimal('0.1'),
        line_total: 90,
        tax_rate: BigDecimal('0.1')
      }

      [ explicit_item, count_item ].each do |item|
        candidates = generate(items: [ item ], context: :analysis)

        expect(candidates.map(&:candidate_id)).not_to include(
          a_string_matching(%r{/original_line_total\z})
        ), item[:pricing_source_kind]
      end
    end

    it 'receipt input候補はreference netをgrossへ投影しsource metadataとreceipt totalsを維持する' do
      candidates = generate(
        receipt: { subtotal_amount: 100, tax_amount: 10, total_amount: 110 },
        items: [ reference_item(amount: 100, tax_inclusion: 'net') ],
        context: :edit_save
      )

      receipt_input = candidates.find { |candidate| candidate.basis == 'receipt_input_preserved' }

      aggregate_failures do
        expect(receipt_input).to have_attributes(subtotal: 100, tax: 10, purchase_total: 110)
        expect(receipt_input.computed_items.first).to include(
          line_total: 110,
          price: 999,
          pricing_source_kind: 'reference_quantity_price',
          reference_price_amount: 100,
          reference_price_tax_inclusion: 'net'
        )
        expect(receipt_input.calculation_profile).not_to have_key(:item_amount_basis_assignments)
      end
    end

    it 'receipt input候補はreference grossのitem金額を変更しない' do
      candidates = generate(
        receipt: { subtotal_amount: 100, tax_amount: 10, total_amount: 110 },
        items: [ reference_item(amount: 110, tax_inclusion: 'gross') ],
        context: :edit_save
      )

      receipt_input = candidates.find { |candidate| candidate.basis == 'receipt_input_preserved' }

      expect(receipt_input.computed_items.first).to include(
        line_total: 110,
        price: 999,
        reference_price_amount: 110,
        reference_price_tax_inclusion: 'gross'
      )
    end

    it '印字税内訳候補は全pathでreference netを一度だけgrossへ投影する' do
      candidates = generate(
        receipt: { subtotal_amount: 100, tax_amount: 10, total_amount: 110 },
        items: [ reference_item(amount: 100, tax_inclusion: 'net', tax_rate: nil) ],
        tax_details: [
          { rate: BigDecimal('0.10'), net_amount: 100, amount: 10, description: '10%対象' }
        ],
        context: :analysis
      )

      printed = candidates.select do |candidate|
        %w[
          printed_tax_details_gross
          printed_tax_details_net
          external_tax_from_receipt
          printed_tax_details_raw_sum
        ].include?(candidate.basis)
      end

      aggregate_failures do
        expect(printed.map(&:basis)).to contain_exactly(
          'printed_tax_details_gross',
          'printed_tax_details_net',
          'external_tax_from_receipt',
          'printed_tax_details_raw_sum'
        )
        expect(printed.map { |candidate| candidate.computed_items.first[:line_total] }).to all(eq(110))
        expect(printed.map { |candidate| candidate.computed_items.first[:price] }).to all(eq(999))
        expect(printed.index_by(&:basis).transform_values(&:purchase_total)).to eq(
          'printed_tax_details_gross' => 100,
          'printed_tax_details_net' => 110,
          'external_tax_from_receipt' => 100,
          'printed_tax_details_raw_sum' => 110
        )
        expect(printed.map(&:calculation_profile)).to all(
          satisfy { |profile| !profile.key?(:item_amount_basis_assignments) }
        )
      end
    end

    it '不完全税内訳候補は明示receipt tax rateがあるreference netをgrossへ投影する' do
      candidates = generate(
        receipt: { total_amount: 100, tax_amount: 10, tax_rate: BigDecimal('0.10') },
        items: [ reference_item(amount: 100, tax_inclusion: 'net', tax_rate: nil) ],
        tax_details: [ { description: '内消費税等', amount: 10 } ],
        context: :analysis
      )

      incomplete = candidates.find { |candidate| candidate.basis == 'incomplete_tax_details_receipt_tax' }

      aggregate_failures do
        expect(incomplete).to have_attributes(subtotal: 90, tax: 10, purchase_total: 100)
        expect(incomplete.computed_items.first).to include(
          line_total: 110,
          price: 999,
          reference_price_tax_inclusion: 'net'
        )
        expect(incomplete.calculation_profile).not_to have_key(:item_amount_basis_assignments)
      end
    end

    it '税率根拠のないreference netをpass-through候補として成立させない' do
      aggregate_failures do
        [ nil, 'invalid' ].each do |tax_rate|
          candidates = generate(
            receipt: { total_amount: 100, tax_amount: 10 },
            items: [ reference_item(amount: 100, tax_inclusion: 'net', tax_rate: tax_rate) ],
            tax_details: [ { description: '内消費税等', amount: 10 } ],
            context: :analysis
          )

          expect(candidates).to be_empty, tax_rate.inspect
        end
      end
    end

    it '非課税らしい商品textだけでreference netの税率を0%へ推測しない' do
      candidates = generate(
        items: [
          reference_item(
            amount: 100,
            tax_inclusion: 'net',
            tax_rate: nil,
            raw_text: 'サンプル非課税券'
          )
        ],
        context: :analysis
      )

      expect(candidates).to be_empty
    end

    it '単一税率の完全な内訳と未解決の値付き内訳が混在するとreference netの税率を推測しない' do
      candidates = generate(
        items: [ reference_item(amount: 100, tax_inclusion: 'net', tax_rate: nil) ],
        tax_details: [
          { rate: BigDecimal('0.10'), net_amount: 100, amount: 10, description: '10%対象' },
          { rate: nil, net_amount: nil, amount: 8, description: '税額のみ' }
        ],
        context: :analysis
      )

      expect(candidates).to be_empty
    end

    it '明示0%のreference netはgrossと同額の有効候補として維持する' do
      candidates = generate(
        items: [ reference_item(amount: 100, tax_inclusion: 'net', tax_rate: BigDecimal('0')) ],
        context: :analysis
      )

      included = candidates.find do |candidate|
        candidate.basis == 'items_as_tax_included' && candidate.rounding_scope == :per_item
      end

      aggregate_failures do
        expect(included).to have_attributes(subtotal: 100, tax: 0, purchase_total: 100)
        expect(included.computed_items.first).to include(
          line_total: 100,
          price: 999,
          tax_rate: BigDecimal('0'),
          reference_price_tax_inclusion: 'net'
        )
      end
    end

    it '税率不明のreference grossは投影不要のため記録額候補を維持する' do
      candidates = generate(
        items: [ reference_item(amount: 100, tax_inclusion: 'gross', tax_rate: nil) ],
        context: :analysis
      )
      included = candidates.find do |candidate|
        candidate.basis == 'items_as_tax_included' && candidate.rounding_scope == :per_item
      end

      aggregate_failures do
        expect(included).to have_attributes(subtotal: 100, tax: 0, purchase_total: 100)
        expect(included.computed_items.first).to include(
          line_total: 100,
          price: 999,
          reference_price_tax_inclusion: 'gross'
        )
      end
    end

    it 'item・単一税内訳・receiptの信頼できる税率を全familyで同じく投影する' do
      cases = {
        item: {
          receipt: {},
          item_tax_rate: BigDecimal('0.10'),
          tax_details: []
        },
        tax_detail: {
          receipt: {},
          item_tax_rate: nil,
          tax_details: [
            { rate: BigDecimal('0.10'), net_amount: 100, amount: 10, description: '10%対象' }
          ]
        },
        receipt: {
          receipt: { tax_rate: BigDecimal('0.10') },
          item_tax_rate: nil,
          tax_details: []
        }
      }

      aggregate_failures do
        cases.each do |source, setup|
          candidates = generate(
            receipt: setup[:receipt],
            items: [ reference_item(amount: 100, tax_inclusion: 'net', tax_rate: setup[:item_tax_rate]) ],
            tax_details: setup[:tax_details],
            context: :analysis
          )
          included = candidates.find do |candidate|
            candidate.basis == 'items_as_tax_included' && candidate.rounding_scope == :per_item
          end

          expect(included).to have_attributes(subtotal: 100, tax: 10, purchase_total: 110), source.to_s
          expect(included.computed_items.first[:line_total]).to eq(110), source.to_s
        end
      end
    end

    it 'uniform candidate内でもreference gross/netをitem単位で固定して税率groupを投影する' do
      candidates = generate(
        items: [
          reference_item(amount: 104, tax_inclusion: 'net'),
          reference_item(amount: 104, tax_inclusion: 'gross'),
          {
            pricing_source_kind: 'explicit_line_total',
            quantity: 1,
            quantity_unit_code: 'each',
            price: 104,
            line_total: 104,
            tax_rate: BigDecimal('0.10'),
            reference_price_amount: 999,
            reference_quantity: 1,
            reference_quantity_unit_code: 'each',
            reference_price_tax_inclusion: 'net'
          }
        ]
      )

      included = candidates.find do |candidate|
        candidate.basis == 'items_as_tax_included' && candidate.rounding_scope == :per_tax_rate_group
      end

      aggregate_failures do
        # net 104円 -> 税10円・gross 114円。gross source 104円とlegacy gross 104円は
        # 同じgross partitionで税18円となり、合計 gross 322円 / net 294円 / 税28円。
        expect(included).to have_attributes(purchase_total: 322, subtotal: 294, tax: 28)
        expect(included.computed_items.map { |item| item[:line_total] }).to eq([ 114, 104, 104 ])
        expect(included.computed_items.first(2).map { |item| item[:price] }).to eq([ 999, 999 ])
        expect(included.computed_items.first(2).map { |item| item[:reference_price_tax_inclusion] })
          .to eq(%w[net gross])
        expect(included.calculation_profile).to include(item_amount_basis: :mixed_by_tax_rate_group)
        expect(included.calculation_profile).not_to have_key(:item_amount_basis_assignments)
      end
    end

    it 'tax excluded候補でもreference source priceをderived gross単価へ書き換えない' do
      candidates = generate(
        items: [
          reference_item(amount: 100, tax_inclusion: 'net'),
          reference_item(amount: 110, tax_inclusion: 'gross')
        ]
      )

      excluded = candidates.find do |candidate|
        candidate.basis == 'items_as_tax_excluded' && candidate.rounding_scope == :per_item
      end

      aggregate_failures do
        expect(excluded).to have_attributes(purchase_total: 220, subtotal: 200, tax: 20)
        expect(excluded.computed_items.map { |item| item[:line_total] }).to eq([ 110, 110 ])
        expect(excluded.computed_items.map { |item| item[:price] }).to eq([ 999, 999 ])
        expect(excluded.calculation_profile).to include(item_amount_basis: :mixed_by_tax_rate_group)
        expect(excluded.calculation_profile).not_to have_key(:item_amount_basis_assignments)
      end
    end

    it '単一reference basisのcandidate profileは保存sourceのgross/netを説明する' do
      cases = {
        'gross' => :line_total_as_recorded,
        'net' => :line_total_as_net
      }

      aggregate_failures do
        cases.each do |tax_inclusion, expected_basis|
          candidates = generate(items: [ reference_item(amount: 100, tax_inclusion: tax_inclusion) ])
          included = candidates.find do |candidate|
            candidate.basis == 'items_as_tax_included' && candidate.rounding_scope == :per_item
          end

          expect(included.calculation_profile).to include(item_amount_basis: expected_basis), tax_inclusion
          expect(included.calculation_profile).not_to have_key(:item_amount_basis_assignments), tax_inclusion
        end
      end
    end

    it 'mixed探索ではreference basisを1候補に固定しlegacy推測flagがoffでもnet sourceを維持する' do
      candidates = generate(
        receipt: { subtotal_amount: 300, tax_amount: 30, total_amount: 330 },
        items: [
          reference_item(amount: 100, tax_inclusion: 'net'),
          reference_item(amount: 220, tax_inclusion: 'gross')
        ],
        tax_details: [
          { rate: BigDecimal('0.10'), net_amount: 330, amount: 30, description: '10%対象' }
        ],
        tax_excluded_price_conversion_enabled: false
      )

      mixed = candidates.find { |candidate| candidate.basis == 'mixed_by_tax_rate_group' }

      aggregate_failures do
        expect(mixed).to have_attributes(purchase_total: 330, subtotal: 300, tax: 30)
        expect(mixed.hard_reject_reasons).to be_empty
        expect(mixed.warnings).not_to include(:price_tax_inclusion_uncertain)
        expect(mixed.computed_items.map { |item| item[:line_total] }).to eq([ 110, 220 ])
        expect(mixed.computed_items.map { |item| item[:price] }).to eq([ 999, 999 ])
        assignments = mixed.evidence.select { |entry| entry[:source] == 'receipt_items' }
        expect(assignments.map { |entry| entry[:basis] }).to contain_exactly(:tax_excluded, :tax_included)
        expect(mixed.calculation_profile).to include(item_amount_basis: :mixed_by_tax_rate_group)
        expect(mixed.calculation_profile).not_to have_key(:item_amount_basis_assignments)
      end
    end

    it '印字税詳細がreference sourceと不一致でも保存済みbasisをuncertainへ戻さない' do
      candidates = generate(
        items: [
          reference_item(amount: 100, tax_inclusion: 'net'),
          reference_item(amount: 220, tax_inclusion: 'gross')
        ],
        tax_details: [
          { rate: BigDecimal('0.10'), net_amount: 331, amount: 30, description: '10%対象' }
        ]
      )

      mixed = candidates.find { |candidate| candidate.basis == 'mixed_by_tax_rate_group' }

      aggregate_failures do
        expect(mixed.hard_reject_reasons).to include(:tax_detail_mismatch)
        expect(mixed.warnings).not_to include(:price_tax_inclusion_uncertain)
        expect(mixed.computed_items.map { |item| item[:line_total] }).to eq([ 100, 220 ])
      end
    end

    it 'analysisのlegacy discounted-original候補でもreference formulaへdiscountを二重適用しない' do
      candidates = generate(
        items: [
          reference_item(
            amount: 100,
            tax_inclusion: 'net',
            original_line_total: 999,
            discount_amount: 10,
            line_total: 999
          ),
          {
            pricing_source_kind: nil,
            quantity: 1,
            quantity_unit_code: 'each',
            price: nil,
            original_line_total: 110,
            discount_amount: 10,
            line_total: 100,
            tax_rate: BigDecimal('0.10')
          }
        ],
        context: :analysis
      )

      original_candidate = candidates.find do |candidate|
        candidate.candidate_id == 'items_as_tax_excluded/floor/per_item/original_line_total'
      end

      aggregate_failures do
        # reference rowは100円から割引10円を一度だけ適用したnet 90円をgross 99円へ投影する。
        # legacy rowだけがoriginal 110円へ戻る。
        expect(original_candidate.computed_items.map { |item| item[:line_total] }).to eq([ 99, 121 ])
        expect(original_candidate.computed_items.first).to include(
          original_line_total: 100,
          discount_amount: 10,
          price: 999
        )
      end
    end

    it 'tax candidate数を増やしてもunit extensionをitem normalizationより下で繰り返さない' do
      expect(Amounts::ReferenceItemExtension).to receive(:call).twice.and_call_original

      generate(
        items: [
          reference_item(amount: 100, tax_inclusion: 'net'),
          reference_item(amount: 110, tax_inclusion: 'gross')
        ],
        tax_rounding_modes: %i[floor round ceil]
      )
    end

    it 'taxとdiscountの各rounding candidateで現在のitemを再投影しstaleなassignmentを保持しない' do
      candidates = generate(
        items: [
          reference_item(
            amount: 15,
            tax_inclusion: 'net',
            discount_rate: BigDecimal('0.10')
          )
        ],
        tax_rounding_modes: %i[floor ceil],
        discount_rounding_modes: %i[floor round]
      )

      projected = candidates.select do |candidate|
        candidate.basis == 'items_as_tax_included' && candidate.rounding_scope == :per_item
      end.index_by do |candidate|
        [ candidate.rounding_mode, candidate.calculation_profile[:discount_rounding_mode] ]
      end

      aggregate_failures do
        expect(projected.fetch(%i[floor floor]).computed_items.first).to include(discount_amount: 1, line_total: 15)
        expect(projected.fetch(%i[ceil floor]).computed_items.first).to include(discount_amount: 1, line_total: 16)
        expect(projected.fetch(%i[floor round]).computed_items.first).to include(discount_amount: 2, line_total: 14)
        expect(projected.fetch(%i[ceil round]).computed_items.first).to include(discount_amount: 2, line_total: 15)
        expect(projected.values.map { |candidate| candidate.calculation_profile[:item_amount_basis] })
          .to all(eq(:line_total_as_net))
        expect(projected.values.map(&:calculation_profile))
          .to all(satisfy { |profile| !profile.key?(:item_amount_basis_assignments) })
      end
    end

    it 'complete reference formulaの0円を有効なitem dataとして候補生成する' do
      candidates = generate(
        items: [ reference_item(amount: 0, tax_inclusion: 'gross', price: nil, line_total: nil) ],
        context: :manual
      )

      aggregate_failures do
        expect(candidates.map(&:basis)).to include('items_as_tax_included')
        expect(candidates.map(&:basis)).not_to include('receipt_input_preserved')
        included = candidates.find { |candidate| candidate.basis == 'items_as_tax_included' }
        expect(included).to have_attributes(purchase_total: 0, subtotal: 0, tax: 0)
        expect(included.computed_items.first).to include(
          pricing_source_kind: 'reference_quantity_price',
          reference_price_amount: 0,
          line_total: 0
        )
      end
    end
  end
end
