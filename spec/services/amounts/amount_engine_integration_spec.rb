require 'rails_helper'

RSpec.describe 'Amount Engine integration' do
  def call_amount_engine(receipt:, items:, tax_details: [], adjustments: [], payments: [], context: :analysis)
    ReceiptAmountService.call(
      receipt: receipt,
      receipt_items: items,
      receipt_tax_details: tax_details,
      receipt_adjustments: adjustments,
      receipt_payments: payments,
      context: context
    )
  end

  def matrix_tax_from_gross(gross, rate)
    rate = BigDecimal(rate.to_s)
    return 0 if rate.zero?

    (BigDecimal(gross.to_s) * rate / (1 + rate)).floor
  end

  def matrix_tax_from_net(net, rate)
    rate = BigDecimal(rate.to_s)
    return 0 if rate.zero?

    (BigDecimal(net.to_s) * rate).floor
  end

  def matrix_taxable_items(rate:, state:)
    included_amount = rate == BigDecimal('0.08') ? 108 : 110

    case state
    when :included
      [ matrix_item(name: "#{(rate * 100).to_i}%税込", amount: included_amount, rate: rate, basis: :tax_included) ]
    when :excluded
      [ matrix_item(name: "#{(rate * 100).to_i}%税抜", amount: 100, rate: rate, basis: :tax_excluded) ]
    when :mixed
      [
        matrix_item(name: "#{(rate * 100).to_i}%税抜", amount: 100, rate: rate, basis: :tax_excluded),
        matrix_item(name: "#{(rate * 100).to_i}%税込", amount: included_amount * 2, rate: rate, basis: :tax_included)
      ]
    else
      []
    end
  end

  def matrix_item(name:, amount:, rate:, basis:)
    {
      raw_text: name,
      suggested_name: name,
      price: amount,
      quantity: 1,
      quantity_unit_code: 'each',
      line_total: amount,
      tax_rate: rate,
      basis: basis
    }
  end

  def matrix_expected(rows)
    expected_rows = rows.map do |row|
      input = row[:line_total]
      gross = row[:basis] == :tax_excluded ? input + matrix_tax_from_net(input, row[:tax_rate]) : input
      tax = matrix_tax_from_gross(gross, row[:tax_rate])
      row.merge(expected_gross: gross, expected_tax: tax, expected_net: gross - tax)
    end
    groups = expected_rows.group_by { |row| row[:tax_rate] }.transform_values do |group_rows|
      gross = group_rows.sum { |row| row[:expected_gross] }
      tax = group_rows.sum { |row| row[:expected_tax] }
      { gross: gross, tax: tax, net: gross - tax }
    end

    {
      rows: expected_rows,
      groups: groups,
      subtotal: groups.values.sum { |group| group[:net] },
      tax: groups.values.sum { |group| group[:tax] },
      total: groups.values.sum { |group| group[:gross] }
    }
  end

  def matrix_case(state8:, state10:, non_taxable:)
    rows = []
    rows.concat(matrix_taxable_items(rate: BigDecimal('0.08'), state: state8))
    rows.concat(matrix_taxable_items(rate: BigDecimal('0.10'), state: state10))
    rows << matrix_item(name: '非課税', amount: 80, rate: BigDecimal('0'), basis: :non_taxable) if non_taxable

    expected = matrix_expected(rows)
    {
      id: "8%:#{state8 || 'none'} 10%:#{state10 || 'none'} non_taxable:#{non_taxable}",
      rows: rows,
      expected: expected,
      tax_details: matrix_tax_details(expected)
    }
  end

  def matrix_tax_details(expected)
    expected[:groups].filter_map do |rate, group|
      next if rate.zero?

      {
        rate: rate,
        net_amount: group[:gross],
        amount: group[:tax],
        description: "#{(rate * 100).to_i}%対象"
      }
    end
  end

  it '2019年サンプルコンビニの税抜/税込/非課税/支払調整混在レシートを候補検算で解決する' do
    result = call_amount_engine(
      receipt: {
        subtotal_amount: 1_390,
        tax_amount: 125,
        total_amount: 1_515
      },
      items: [
        { price: 130, quantity: 1, quantity_unit_code: 'each', line_total: 130, tax_rate: BigDecimal('0.08') },
        { price: 140, quantity: 1, quantity_unit_code: 'each', line_total: 140, tax_rate: BigDecimal('0.08') },
        { price: 300, quantity: 1, quantity_unit_code: 'each', line_total: 300, tax_rate: BigDecimal('0.10') },
        { price: 490, quantity: 1, quantity_unit_code: 'each', line_total: 490, tax_rate: BigDecimal('0.10') },
        { price: 50, quantity: 1, quantity_unit_code: 'each', line_total: 50, tax_rate: BigDecimal('0') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 270, amount: 21, description: '8%対象' },
        { rate: BigDecimal('0.10'), net_amount: 300, amount: 30, description: '小計（税抜10%）' },
        { rate: BigDecimal('0.10'), net_amount: 820, amount: 74, description: '10%対象' }
      ],
      adjustments: [
        {
          kind: 'other',
          label: 'キャッシュレス還元額',
          source_text: 'キャッシュレス還元額 -22',
          sign: 'discount',
          amount: 22,
          source: 'ocr'
        }
      ],
      payments: [
        { method: 'nanaco', amount: 1_139 }
      ]
    )

    aggregate_failures do
      # 検算:
      # 8%: 130税抜 -> price/line_total 140税込, 140税抜 -> price/line_total 151税込, 税込291 / 税21 / 税抜270
      # 10%: 300税抜 -> price/line_total 330税込, 490税込は据え置き, 税込820 / 税 floor(820 * 10 / 110)=74 / 税抜746
      # 0%: 50。購入合計 291 + 820 + 50 = 1,161。支払調整 -22 で final 1,139。
      expect(result[:resolved]).to include(subtotal: 1_066, tax: 95, total: 1_161, tax_rate: nil)
      expect(result.dig(:computed, :final_payment_total)).to eq(1_139)
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(-22)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_139)
      expect(result.dig(:computed, :items).map { |item| item['price'] || item[:price] }).to eq([ 140, 151, 330, 490, 50 ])
      expect(result.dig(:computed, :items).map { |item| item['line_total'] || item[:line_total] }).to eq([ 140, 151, 330, 490, 50 ])
      expect(result.dig(:computed, :items).map { |item| item['tax_rate'] || item[:tax_rate] }).to eq([
        BigDecimal('0.08'),
        BigDecimal('0.08'),
        BigDecimal('0.10'),
        BigDecimal('0.10'),
        BigDecimal('0')
      ])
      expect(result.dig(:amount_engine, :selected_candidate, :computed_items).map { |item| item[:price] }).to eq([ 140, 151, 330, 490, 50 ])
      expect(result[:tax_details]).to contain_exactly(
        include(rate: BigDecimal('0.08'), net_amount: 270, amount: 21),
        include(rate: BigDecimal('0.10'), net_amount: 746, amount: 74)
      )
      expect(result.dig(:computed, :item_amount_basis)).to eq(:mixed_by_tax_rate_group)
      expect(result.dig(:computed, :tax_rate_groups).map { |group| group[:rate] }).to contain_exactly(
        BigDecimal('0.08'),
        BigDecimal('0.10'),
        BigDecimal('0')
      )
      expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('mixed_by_tax_rate_group/floor')
      expect(result[:blocking_inconsistencies]).to be_empty
      expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
      expect(result[:review_reasons]).to include('price_tax_inclusion_uncertain')
      expect(result[:needs_review]).to be(true)
    end
  end

  it '印字税詳細と完全一致する税抜/税込混在では税込補正済みmixed候補を採用する' do
    result = call_amount_engine(
      receipt: {
        subtotal_amount: 300,
        tax_amount: 30,
        total_amount: 330
      },
      items: [
        { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, tax_rate: BigDecimal('0.10') },
        { price: 220, quantity: 1, quantity_unit_code: 'each', line_total: 220, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.10'), net_amount: 330, amount: 30, description: '10%対象' }
      ],
      payments: [
        { method: 'cash', amount: 330 }
      ]
    )

    aggregate_failures do
      # 検算: 100税抜 -> 110税込、220税込は据え置き。税込対象330 / 税30 / 税抜300。
      expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('mixed_by_tax_rate_group/floor')
      expect(result[:resolved]).to include(subtotal: 300, tax: 30, total: 330, tax_rate: BigDecimal('0.10'))
      expect(result.dig(:computed, :final_payment_total)).to eq(330)
      expect(result.dig(:computed, :items).map { |item| item[:price] }).to eq([ 110, 220 ])
      expect(result.dig(:computed, :items).map { |item| item[:line_total] }).to eq([ 110, 220 ])
      expect(result.dig(:computed, :items).map { |item| item[:original_line_total] }).to eq([ 100, 220 ])
      expect(result[:blocking_inconsistencies]).to be_empty
    end
  end

  it '印字税詳細と完全一致する税抜/非課税混在では税込補正済みmixed候補を採用する' do
    result = call_amount_engine(
      receipt: {
        subtotal_amount: 150,
        tax_amount: 10,
        total_amount: 160
      },
      items: [
        { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, tax_rate: BigDecimal('0.10') },
        { price: 50, quantity: 1, quantity_unit_code: 'each', line_total: 50, tax_rate: BigDecimal('0') }
      ],
      tax_details: [
        { rate: BigDecimal('0.10'), net_amount: 110, amount: 10, description: '10%対象' }
      ],
      payments: [
        { method: 'cash', amount: 160 }
      ]
    )

    aggregate_failures do
      # 検算: 100税抜 -> 110税込、非課税50は据え置き。購入合計160。
      expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('mixed_by_tax_rate_group/floor')
      expect(result[:resolved]).to include(subtotal: 150, tax: 10, total: 160, tax_rate: BigDecimal('0.10'))
      expect(result.dig(:computed, :items).map { |item| item[:price] }).to eq([ 110, 50 ])
      expect(result.dig(:computed, :items).map { |item| item[:line_total] }).to eq([ 110, 50 ])
      expect(result.dig(:computed, :items).map { |item| item[:original_line_total] }).to eq([ 100, 50 ])
      expect(result[:blocking_inconsistencies]).to be_empty
    end
  end

  it '税込/非課税混在では不要な税込補正を行わない' do
    result = call_amount_engine(
      receipt: {
        subtotal_amount: 150,
        tax_amount: 10,
        total_amount: 160
      },
      items: [
        { price: 110, quantity: 1, quantity_unit_code: 'each', line_total: 110, tax_rate: BigDecimal('0.10') },
        { price: 50, quantity: 1, quantity_unit_code: 'each', line_total: 50, tax_rate: BigDecimal('0') }
      ],
      tax_details: [
        { rate: BigDecimal('0.10'), net_amount: 110, amount: 10, description: '10%対象' }
      ],
      payments: [
        { method: 'cash', amount: 160 }
      ]
    )

    aggregate_failures do
      # 検算: どちらの明細も入力値が税込/非課税として整合するため据え置く。
      expect(result[:resolved]).to include(subtotal: 150, tax: 10, total: 160, tax_rate: BigDecimal('0.10'))
      expect(result.dig(:computed, :items).map { |item| item[:price] }).to eq([ 110, 50 ])
      expect(result.dig(:computed, :items).map { |item| item[:line_total] }).to eq([ 110, 50 ])
      expect(result.dig(:computed, :items).map { |item| item[:original_line_total] }).to eq([ 110, 50 ])
      expect(result[:blocking_inconsistencies]).to be_empty
    end
  end

  it '全部税抜単価で印字税詳細と完全一致する場合も税込補正済みmixed候補を採用する' do
    result = call_amount_engine(
      receipt: {
        subtotal_amount: 400,
        tax_amount: 38,
        total_amount: 438
      },
      items: [
        { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, tax_rate: BigDecimal('0.08') },
        { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, tax_rate: BigDecimal('0.10') },
        { price: 200, quantity: 1, quantity_unit_code: 'each', line_total: 200, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 108, amount: 8, description: '8%対象' },
        { rate: BigDecimal('0.10'), net_amount: 330, amount: 30, description: '10%対象' }
      ],
      payments: [
        { method: 'cash', amount: 438 }
      ]
    )

    aggregate_failures do
      # 検算: 8%税抜100 -> 108税込。10%税抜100/200 -> 110/220税込。購入合計438。
      expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('mixed_by_tax_rate_group/floor')
      expect(result[:resolved]).to include(subtotal: 400, tax: 38, total: 438, tax_rate: nil)
      expect(result.dig(:computed, :items).map { |item| item[:price] }).to eq([ 108, 110, 220 ])
      expect(result.dig(:computed, :items).map { |item| item[:line_total] }).to eq([ 108, 110, 220 ])
      expect(result.dig(:computed, :items).map { |item| item[:original_line_total] }).to eq([ 100, 100, 200 ])
      expect(result[:blocking_inconsistencies]).to be_empty
    end
  end

  it '税率グループ単位の税込/税抜/非課税30通りで明細税込化と合計を保つ' do
    states = [ nil, :included, :excluded, :mixed ]
    cases = states.product(states, [ false, true ]).filter_map do |state8, state10, non_taxable|
      next if state8.nil? && state10.nil?

      matrix_case(state8: state8, state10: state10, non_taxable: non_taxable)
    end

    aggregate_failures do
      expect(cases.size).to eq(30)

      cases.each do |test_case|
        expected = test_case[:expected]
        result = call_amount_engine(
          receipt: {
            subtotal_amount: expected[:subtotal],
            tax_amount: expected[:tax],
            total_amount: expected[:total]
          },
          items: test_case[:rows].map { |row| row.except(:basis) },
          tax_details: test_case[:tax_details],
          payments: [
            { method: 'cash', amount: expected[:total] }
          ]
        )

        aggregate_failures test_case[:id] do
          expected_line_totals = expected[:rows].map { |row| row[:expected_gross] }
          expected_original_line_totals = test_case[:rows].map { |row| row[:line_total] }

          expect(result[:resolved]).to include(
            subtotal: expected[:subtotal],
            tax: expected[:tax],
            total: expected[:total]
          )
          expect(result.dig(:computed, :final_payment_total)).to eq(expected[:total])
          expect(result.dig(:computed, :items).map { |item| item[:line_total] }).to eq(expected_line_totals)
          expect(result.dig(:computed, :items).map { |item| item[:price] }).to eq(expected_line_totals)
          expect(result.dig(:computed, :items).map { |item| item[:original_line_total] }).to eq(expected_original_line_totals)
          expect(result[:blocking_inconsistencies]).to be_empty

          if test_case[:rows].any? { |row| row[:basis] == :tax_excluded }
            expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('mixed_by_tax_rate_group/floor')
          end
        end
      end
    end
  end

  it '複数税率への再割当が複数通り完全一致する場合はsilent completedにしない' do
    allow(SystemSettings).to receive(:enabled?)
      .with(ReceiptAmountService::TAX_EXCLUDED_PRICE_CONVERSION_SETTING_KEY)
      .and_return(true)

    result = call_amount_engine(
      receipt: {
        subtotal_amount: 184,
        tax_amount: 16,
        total_amount: 200
      },
      items: [
        { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, tax_rate: BigDecimal('0.10') },
        { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 93, amount: 7, description: '小計（税抜8%）' },
        { rate: BigDecimal('0.10'), net_amount: 91, amount: 9, description: '小計（税抜10%）' }
      ]
    )

    aggregate_failures do
      # 検算: 同額2行はどちらを8%/10%へ割り当ててもexactになるため、税率補正を自動確定しない。
      expect(result[:warning_inconsistencies]).to include(:competing_exact_basis_candidate)
      expect(result[:review_reasons]).to include('competing_exact_basis_candidate')
      expect(result[:needs_review]).to be(true)
    end
  end

  it '複数税率への再割当探索がitem数上限に達したらsilent completedにしない' do
    stub_const('Amounts::CandidateGenerator::SAME_RATE_MIXED_MAX_ITEMS', 1)
    allow(SystemSettings).to receive(:enabled?)
      .with(ReceiptAmountService::TAX_EXCLUDED_PRICE_CONVERSION_SETTING_KEY)
      .and_return(true)

    result = call_amount_engine(
      receipt: {
        subtotal_amount: 184,
        tax_amount: 16,
        total_amount: 200
      },
      items: [
        { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, tax_rate: BigDecimal('0.10') },
        { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 93, amount: 7, description: '小計（税抜8%）' },
        { rate: BigDecimal('0.10'), net_amount: 91, amount: 9, description: '小計（税抜10%）' }
      ]
    )

    aggregate_failures do
      expect(result[:warning_inconsistencies]).to include(:mixed_basis_search_truncated)
      expect(result[:review_reasons]).to include('mixed_basis_search_truncated')
      expect(result[:needs_review]).to be(true)
    end
  end

  it '2019年サンプルコンビニのOCR descriptionが潰れた再解析データでもlegacyではなく混在候補を採用する' do
    result = call_amount_engine(
      receipt: {
        subtotal_amount: 10,
        tax_amount: 125,
        total_amount: 1_161
      },
      items: [
        { price: 130, quantity: 1, quantity_unit_code: 'each', line_total: 130, tax_rate: BigDecimal('0.08') },
        { price: 140, quantity: 1, quantity_unit_code: 'each', line_total: 140, tax_rate: BigDecimal('0.08') },
        { price: 300, quantity: 1, quantity_unit_code: 'each', line_total: 300, tax_rate: BigDecimal('0.10') },
        { price: 490, quantity: 1, quantity_unit_code: 'each', line_total: 490, tax_rate: BigDecimal('0.10') },
        { price: 50, quantity: 1, quantity_unit_code: 'each', line_total: 50, tax_rate: BigDecimal('0') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 270, amount: 21, description: '消費税等' },
        { rate: BigDecimal('0.10'), net_amount: 300, amount: 30, description: '消費税等' },
        { rate: BigDecimal('0.10'), net_amount: 820, amount: 74, description: '内消費税等' }
      ],
      adjustments: [
        {
          kind: 'receipt_discount',
          label: 'キャッシュレス還元額',
          source_text: 'キャッシュレス還元額 -22',
          sign: 'discount',
          amount: 22,
          source: 'ai',
          needs_review: true
        }
      ],
      payments: [
        { method: 'nanaco支払', amount: 1_139 }
      ]
    )

    selected = result.dig(:amount_engine, :selected_candidate)

    aggregate_failures do
      # 検算:
      # 8%: 130税抜 -> price/line_total 140税込, 140税抜 -> price/line_total 151税込, gross=291, tax=21。
      # 10%: 300税抜 -> price/line_total 330税込, 490税込は据え置き, gross=820, tax=floor(820 * 10 / 110)=74。
      # 0%: 50。purchase_total=291 + 820 + 50 = 1,161。cashless_reward=-22でfinal=1,139。
      expect(result[:resolved]).to include(subtotal: 1_066, tax: 95, total: 1_161, tax_rate: nil)
      expect(result.dig(:amount_engine, :selected_basis)).to eq('mixed_by_tax_rate_group')
      expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('mixed_by_tax_rate_group/floor')
      expect(selected).to include(
        purchase_total: 1_161,
        final_payment_total: 1_139,
        payment_adjustment_total: -22,
        payment_amount_sum: 1_139
      )
      expect(result.dig(:computed, :items).map { |item| item['price'] || item[:price] }).to eq([ 140, 151, 330, 490, 50 ])
      expect(result.dig(:computed, :items).map { |item| item['line_total'] || item[:line_total] }).to eq([ 140, 151, 330, 490, 50 ])
      expect(result[:review_reasons]).to include('price_tax_inclusion_uncertain')
      expect(result[:amount_engine][:candidates].map { |candidate| candidate[:candidate_id] }).to include('mixed_by_tax_rate_group/floor')
    end
  end

  it '税額0円の小額10%対象を印字TaxDetailsとして含めて購入合計を解決する' do
    result = call_amount_engine(
      receipt: {
        tax_amount: 59,
        total_amount: 801
      },
      items: [
        { raw_text: '商品A', price: 798, quantity: 1, quantity_unit_code: 'each', line_total: 798, tax_rate: BigDecimal('0.08') },
        { raw_text: 'レジ袋', price: 3, quantity: 1, quantity_unit_code: 'each', line_total: 3, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 739, amount: 59, description: '小 計 (税抜8%)' },
        { rate: BigDecimal('0.10'), net_amount: 3, amount: 0, description: '小 計 (税抜10%)' }
      ],
      payments: [
        { method: 'Suica', amount: 801 }
      ]
    )

    aggregate_failures do
      # 検算: 739税抜8% -> 税59, 税込798。3税抜10% -> 税0, 税込3。
      expect(result[:resolved]).to include(subtotal: 742, tax: 59, total: 801, tax_rate: nil)
      expect(result.dig(:computed, :final_payment_total)).to eq(801)
      expect(result.dig(:computed, :tax_rate_groups)).to include(
        include(rate: BigDecimal('0.08'), net: 739, tax: 59, gross: 798),
        include(rate: BigDecimal('0.10'), net: 3, tax: 0, gross: 3)
      )
      expect(result[:needs_review]).to be(false)
      expect(result[:review_reasons]).to be_empty
      expect(result[:blocking_inconsistencies]).not_to include(:tax_detail_mismatch)
      expect(result[:review_reasons]).not_to include('tax_detail_mismatch')
    end
  end

  it 'SystemSettingsで税抜単価の税込補正をOFFにするとanalysisでは税抜補正系候補を生成しない' do
    create(
      :system_setting,
      key: ReceiptAmountService::TAX_EXCLUDED_PRICE_CONVERSION_SETTING_KEY,
      value: SystemSettings.stored_value(false)
    )

    result = call_amount_engine(
      receipt: {
        subtotal_amount: 1_390,
        tax_amount: 125,
        total_amount: 1_515
      },
      items: [
        { price: 130, quantity: 1, quantity_unit_code: 'each', original_line_total: 130, line_total: 130, tax_rate: BigDecimal('0.08') },
        { price: 140, quantity: 1, quantity_unit_code: 'each', original_line_total: 140, line_total: 140, tax_rate: BigDecimal('0.08') },
        { price: 300, quantity: 1, quantity_unit_code: 'each', original_line_total: 300, line_total: 300, tax_rate: BigDecimal('0.10') },
        { price: 490, quantity: 1, quantity_unit_code: 'each', original_line_total: 490, line_total: 490, tax_rate: BigDecimal('0.10') },
        { price: 50, quantity: 1, quantity_unit_code: 'each', original_line_total: 50, line_total: 50, tax_rate: BigDecimal('0') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 270, amount: 21, description: '8%対象' },
        { rate: BigDecimal('0.10'), net_amount: 300, amount: 30, description: '小計（税抜10%）' },
        { rate: BigDecimal('0.10'), net_amount: 820, amount: 74, description: '10%対象' }
      ],
      adjustments: [
        {
          kind: 'other',
          label: 'キャッシュレス還元額',
          source_text: 'キャッシュレス還元額 -22',
          sign: 'discount',
          amount: 22,
          source: 'ocr'
        }
      ],
      payments: [
        { method: 'nanaco', amount: 1_118 }
      ]
    )

    aggregate_failures do
      # 検算: OFF時は130/140/300を税込へ補正しない。TaxDetails gross候補は
      # 8%対象270 + 10%対象820 + 非課税50 = 1,140、税額21 + 74 = 95を候補として残し、
      # 保存subtotalはgross - taxの実netにする。
      expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('printed_tax_details_gross/floor')
      expect(result[:resolved]).to include(subtotal: 1_045, tax: 95, total: 1_140, tax_rate: nil)
      expect(result.dig(:computed, :items).map { |item| item[:price] }).to eq([ 130, 140, 300, 490, 50 ])
      expect(result.dig(:computed, :items).map { |item| item[:line_total] }).to eq([ 130, 140, 300, 490, 50 ])
      expect(result.dig(:computed, :items).map { |item| item[:original_line_total] }).to eq([ 130, 140, 300, 490, 50 ])
      expect(result.dig(:amount_engine, :candidates).map { |candidate| candidate[:candidate_id] }.grep(%r{\Aitems_as_tax_excluded/})).to be_empty
      expect(result.dig(:amount_engine, :selected_candidate, :computed_items).map { |item| item[:price] }).to eq([ 130, 140, 300, 490, 50 ])
    end
  end

  it '税抜単価の税込補正OFFでも外税receipt候補は維持する' do
    create(
      :system_setting,
      key: ReceiptAmountService::TAX_EXCLUDED_PRICE_CONVERSION_SETTING_KEY,
      value: SystemSettings.stored_value(false)
    )

    result = call_amount_engine(
      receipt: { subtotal_amount: 1_000, tax_amount: 100, total_amount: 1_100, tax_rate: BigDecimal('0.10') },
      items: [
        { line_total: 400, tax_rate: BigDecimal('0.10') },
        { line_total: 600, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.10'), net_amount: 1_000, amount: 100, description: '外税10%' }
      ],
      payments: [
        { method: 'cash', amount: 1_100 }
      ]
    )

    aggregate_failures do
      # 検算: 外税候補は明細税込補正ではなく、印字の税抜小計1,000 + 外税100 = 1,100を説明する候補。
      expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('external_tax_from_receipt/floor')
      expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100, tax_rate: BigDecimal('0.10'))
      expect(result.dig(:computed, :items).map { |item| item[:line_total] }).to eq([ 400, 600 ])
    end
  end

  it '税抜単価の税込補正OFFはmanual/edit_saveに影響しない' do
    create(
      :system_setting,
      key: ReceiptAmountService::TAX_EXCLUDED_PRICE_CONVERSION_SETTING_KEY,
      value: SystemSettings.stored_value(false)
    )

    %i[manual edit_save].each do |context|
      result = call_amount_engine(
        receipt: { subtotal_amount: 200, tax_amount: 20, total_amount: 220 },
        items: [
          { price: 100, quantity: 2, quantity_unit_code: 'each', line_total: 200, tax_rate: BigDecimal('0.10') }
        ],
        payments: [
          { method: 'cash', amount: 220 }
        ],
        context: context
      )

      aggregate_failures context do
        # 検算: manual/edit_saveはSystemSettingsの検証用OFFを無視する。
        # 既存挙動どおり、税抜line_total 200 + 10% = 220、税込単価は220 / 2 = 110。
        expect(result.dig(:amount_engine, :selected_candidate_id)).to start_with('items_as_tax_excluded/')
        expect(result[:resolved]).to include(subtotal: 200, tax: 20, total: 220)
        expect(result.dig(:computed, :items).first).to include(price: 110, line_total: 220)
      end
    end
  end

  it 'Amount Engine候補snapshot件数設定はsnapshot件数だけを変え金額計算結果を変えない' do
    receipt = { total_amount: 100 }
    items = [
      { line_total: 100, tax_rate: BigDecimal('0') }
    ]
    default_result = call_amount_engine(receipt: receipt, items: items)

    create(
      :system_setting,
      key: Amounts::CandidateSnapshot::SETTING_KEY,
      value: SystemSettings.stored_value(5)
    )
    expanded_snapshot_result = call_amount_engine(receipt: receipt, items: items)

    aggregate_failures do
      # 検算: 非課税100円なので、snapshot件数に関わらずtotal/subtotal/taxは100/100/0。
      expect(default_result[:resolved]).to include(subtotal: 100, tax: 0, total: 100)
      expect(expanded_snapshot_result[:resolved]).to eq(default_result[:resolved])
      expect(default_result.dig(:amount_engine, :candidates).size).to eq(3)
      expect(expanded_snapshot_result.dig(:amount_engine, :candidates).size).to eq(5)
      expect(expanded_snapshot_result.dig(:amount_engine, :selected_candidate)).to be_present
    end
  end

  it '税抜補正後の税込line_totalを整数数量で割り切れる時だけpriceへ反映する' do
    result = call_amount_engine(
      receipt: { subtotal_amount: 200, tax_amount: 20, total_amount: 220 },
      items: [
        { price: 100, quantity: 2, quantity_unit_code: 'each', line_total: 200, tax_rate: BigDecimal('0.10') }
      ],
      payments: [
        { method: 'cash', amount: 220 }
      ]
    )

    item = result.dig(:computed, :items).first

    aggregate_failures do
      # 検算: 税抜 100円 x 2 = 200円。10%外税で税込line_total 220円、税込単価は 220 / 2 = 110円。
      expect(result[:resolved]).to include(subtotal: 200, tax: 20, total: 220)
      expect(result.dig(:amount_engine, :selected_candidate_id)).to start_with('items_as_tax_excluded/')
      expect(item[:price]).to eq(110)
      expect(item[:line_total]).to eq(220)
    end
  end

  it '割引あり明細は税込line_totalへ補正してもpriceを無理に変更しない' do
    result = call_amount_engine(
      receipt: { subtotal_amount: 100, tax_amount: 10, total_amount: 110 },
      items: [
        { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, discount_rate: BigDecimal('0.10'), tax_rate: BigDecimal('0.10') }
      ],
      payments: [
        { method: 'cash', amount: 110 }
      ]
    )

    item = result.dig(:computed, :items).first

    aggregate_failures do
      # 検算: 税抜line_total 100円を10%外税として税込110円へ補正するが、割引率があるため単価100円は保持する。
      expect(result[:resolved]).to include(subtotal: 100, tax: 10, total: 110)
      expect(item[:price]).to eq(100)
      expect(item[:line_total]).to eq(110)
    end
  end

  it 'スーパーの複数税率とレシート全体値引きを購入合計として計算する' do
    result = call_amount_engine(
      receipt: { subtotal_amount: 800, tax_amount: 78, total_amount: 878 },
      items: [
        { line_total: 216, tax_rate: BigDecimal('0.08') },
        { line_total: 162, tax_rate: BigDecimal('0.08') },
        { line_total: 550, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 378, amount: 28, description: '8%対象' },
        { rate: BigDecimal('0.10'), net_amount: 550, amount: 50, description: '10%対象' }
      ],
      adjustments: [
        { kind: 'receipt_discount', sign: 'discount', amount: 50, source: 'ocr' }
      ],
      payments: [
        { method: 'cash', amount: 878 }
      ]
    )

    aggregate_failures do
      # 検算: 商品税込 216 + 162 + 550 = 928、購入値引き -50、購入合計 878。
      # 税額は印字税額 28 + 50 = 78、税抜は 878 - 78 = 800。
      expect(result[:resolved]).to include(subtotal: 800, tax: 78, total: 878)
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(-50)
      expect(result.dig(:computed, :final_payment_total)).to eq(878)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(878)
      expect(result[:review_reasons]).to include('purchase_adjustment_tax_allocation_uncertain')
      expect(result[:needs_review]).to be(true)
    end
  end

  it 'ドラッグストアのクーポン値引きとポイント利用を購入調整/支払調整に分ける' do
    result = call_amount_engine(
      receipt: { subtotal_amount: 1_500, tax_amount: 150, total_amount: 1_650 },
      items: [
        { line_total: 880, tax_rate: BigDecimal('0.10') },
        { line_total: 330, tax_rate: BigDecimal('0.10') },
        { line_total: 540, tax_rate: BigDecimal('0.08') }
      ],
      tax_details: [
        { rate: BigDecimal('0.10'), net_amount: 1_210, amount: 110, description: '10%対象' },
        { rate: BigDecimal('0.08'), net_amount: 540, amount: 40, description: '8%対象' }
      ],
      adjustments: [
        { kind: 'coupon', sign: 'discount', amount: 100, source: 'ocr' },
        { kind: 'point_usage', sign: 'discount', amount: 200, source: 'ocr' }
      ],
      payments: [
        { method: 'credit', amount: 1_450 }
      ]
    )

    aggregate_failures do
      # 検算: 商品税込 1,750、クーポン -100 で購入合計 1,650。
      # ポイント -200 は支払調整なので final は 1,450。
      expect(result[:resolved]).to include(subtotal: 1_500, tax: 150, total: 1_650)
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(-100)
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(-200)
      expect(result.dig(:computed, :final_payment_total)).to eq(1_450)
      expect(result[:review_reasons]).to include('purchase_adjustment_tax_allocation_uncertain')
      expect(result[:needs_review]).to be(true)
    end
  end

  it 'ポイント・クーポン・キャッシュレス還元・payment discountの符号を崩さずfinal_payment_totalへ反映する' do
    result = call_amount_engine(
      receipt: { total_amount: 1_900 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0') },
        { line_total: 1_000, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        { kind: 'coupon', sign: 'discount', amount: 100, source: 'ocr' },
        { kind: 'point_usage', sign: 'discount', amount: 300, source: 'ocr' },
        { kind: 'receipt_discount', label: 'キャッシュレス還元額', sign: 'discount', amount: 50, source: 'ocr' },
        { kind: 'receipt_discount', label: 'payment discount', sign: 'discount', amount: 40, source: 'ocr' }
      ],
      payments: [
        { method: 'credit', amount: 1_510 }
      ]
    )

    aggregate_failures do
      # 検算: 商品合計2,000、クーポン -100 は購入調整なので購入合計1,900。
      # ポイント -300、キャッシュレス還元 -50、payment discount -40 は支払調整なので実支払額1,510。
      expect(result[:resolved]).to include(subtotal: 1_900, tax: 0, total: 1_900)
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(-100)
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(-390)
      expect(result.dig(:computed, :final_payment_total)).to eq(1_510)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_510)
      expect(result[:blocking_inconsistencies]).to be_empty
      expect(result[:review_reasons]).to be_empty
      expect(result[:needs_review]).to be(false)
    end
  end

  it 'point_usageがadjustmentとpaymentの両方に入っても二重計上しない' do
    result = call_amount_engine(
      receipt: { total_amount: 1_000 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        {
          kind: 'point_usage',
          sign: 'discount',
          amount: 100,
          source_text: 'ポイント利用 -100',
          source_line_index: 10,
          source_span_start: 7,
          source_span_end: 11,
          source: 'ocr'
        }
      ],
      payments: [
        {
          method: 'ポイント利用',
          amount: 100,
          source_text: 'ポイント利用 -100',
          source_line_index: 10,
          source_span_start: 7,
          source_span_end: 11
        },
        { method: 'credit', amount: 900 }
      ]
    )

    aggregate_failures do
      expect(result.dig(:computed, :purchase_total)).to eq(1_000)
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(-100)
      expect(result.dig(:computed, :final_payment_total)).to eq(900)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(900)
      expect(result[:blocking_inconsistencies]).not_to include(:payment_amount_mismatch)
      expect(result[:needs_review]).to be(false)
    end
  end

  it 'cashless rewardが複数adjustment kindで重複しても一度だけ支払調整にする' do
    result = call_amount_engine(
      receipt: { total_amount: 1_000 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        {
          kind: 'receipt_discount', sign: 'discount', amount: 50, source_text: 'キャッシュレス還元 -50',
          source_line_index: 11, source_span_start: 10, source_span_end: 13, source: 'ocr'
        },
        {
          kind: 'other', sign: 'discount', amount: 50, source_text: 'キャッシュレス還元 -50',
          source_line_index: 11, source_span_start: 10, source_span_end: 13, source: 'ocr'
        }
      ],
      payments: [
        { method: 'credit', amount: 950 }
      ]
    )

    aggregate_failures do
      expect(result.dig(:computed, :purchase_total)).to eq(1_000)
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(0)
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(-50)
      expect(result.dig(:computed, :final_payment_total)).to eq(950)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(950)
      expect(result[:blocking_inconsistencies]).to be_empty
      expect(result[:needs_review]).to be(false)
    end
  end

  it '同額couponでもsource lineが異なれば別の購入調整として残す' do
    result = call_amount_engine(
      receipt: { total_amount: 800 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        { kind: 'coupon', sign: 'discount', amount: 100, source_text: 'クーポンA -100', source_line_index: 20, source: 'ocr' },
        { kind: 'coupon', sign: 'discount', amount: 100, source_text: 'クーポンB -100', source_line_index: 21, source: 'ocr' }
      ],
      payments: [
        { method: 'credit', amount: 800 }
      ]
    )

    aggregate_failures do
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(-200)
      expect(result.dig(:computed, :purchase_total)).to eq(800)
      expect(result.dig(:computed, :final_payment_total)).to eq(800)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(800)
      expect(result[:blocking_inconsistencies]).to be_empty
      expect(result[:needs_review]).to be(false)
    end
  end

  it 'provenanceがない同額couponは重複と断定せず別の購入調整として残す' do
    result = call_amount_engine(
      receipt: { total_amount: 800 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        { kind: 'coupon', sign: 'discount', amount: 100, source: 'ocr' },
        { kind: 'coupon', sign: 'discount', amount: 100, source: 'ocr' }
      ],
      payments: [
        { method: 'credit', amount: 800 }
      ]
    )

    aggregate_failures do
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(-200)
      expect(result.dig(:computed, :purchase_total)).to eq(800)
      expect(result.dig(:computed, :final_payment_total)).to eq(800)
      expect(result[:blocking_inconsistencies]).to be_empty
      expect(result[:needs_review]).to be(false)
    end
  end

  it 'provenanceがない同額・同labelのcouponも重複と断定しない' do
    result = call_amount_engine(
      receipt: { total_amount: 800 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        { kind: 'coupon', label: 'クーポン', sign: 'discount', amount: 100, source: 'ocr' },
        { kind: 'coupon', label: 'クーポン', sign: 'discount', amount: 100, source: 'ocr' }
      ],
      payments: [
        { method: 'credit', amount: 800 }
      ]
    )

    aggregate_failures do
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(-200)
      expect(result.dig(:computed, :purchase_total)).to eq(800)
      expect(result[:blocking_inconsistencies]).to be_empty
    end
  end

  it '同じsource line・同額でもspan根拠がなければpurchase/payment adjustmentを誤集約しない' do
    result = call_amount_engine(
      receipt: { total_amount: 900 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        { kind: 'coupon', label: 'クーポン', sign: 'discount', amount: 100, source_line_index: 20, source: 'ocr' },
        { kind: 'point_usage', label: 'ポイント利用', sign: 'discount', amount: 100, source_line_index: 20, source: 'ocr' }
      ],
      payments: [
        { method: 'credit', amount: 800 }
      ]
    )

    aggregate_failures do
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(-100)
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(-100)
      expect(result.dig(:computed, :purchase_total)).to eq(900)
      expect(result.dig(:computed, :final_payment_total)).to eq(800)
      expect(result[:blocking_inconsistencies]).to be_empty
    end
  end

  it '同じsource line・同額でも異なるspanのcouponを別の購入調整として残す' do
    result = call_amount_engine(
      receipt: { total_amount: 800 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        {
          kind: 'coupon', sign: 'discount', amount: 100, source_line_index: 20,
          source_span_start: 4, source_span_end: 8, source: 'ocr'
        },
        {
          kind: 'coupon', sign: 'discount', amount: 100, source_line_index: 20,
          source_span_start: 14, source_span_end: 18, source: 'ocr'
        }
      ],
      payments: [
        { method: 'credit', amount: 800 }
      ]
    )

    aggregate_failures do
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(-200)
      expect(result.dig(:computed, :purchase_total)).to eq(800)
      expect(result[:blocking_inconsistencies]).to be_empty
    end
  end

  it '同額cashless rewardでもsource lineが異なれば別の支払調整として残す' do
    result = call_amount_engine(
      receipt: { total_amount: 1_000 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        { kind: 'receipt_discount', sign: 'discount', amount: 200, source_text: 'キャッシュレス還元A -200', source_line_index: 30, source: 'ocr' },
        { kind: 'receipt_discount', sign: 'discount', amount: 200, source_text: 'キャッシュレス還元B -200', source_line_index: 31, source: 'ocr' }
      ],
      payments: [
        { method: 'credit', amount: 600 }
      ]
    )

    aggregate_failures do
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(0)
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(-400)
      expect(result.dig(:computed, :purchase_total)).to eq(1_000)
      expect(result.dig(:computed, :final_payment_total)).to eq(600)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(600)
      expect(result[:blocking_inconsistencies]).to be_empty
      expect(result[:needs_review]).to be(false)
    end
  end

  it 'point payment行は同額でもsource identityが異なれば支払調整の重複としてdropしない' do
    result = call_amount_engine(
      receipt: { total_amount: 1_000 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        { kind: 'point_usage', sign: 'discount', amount: 100, source_text: 'ポイント利用 -100', source_line_index: 40, source: 'ocr' }
      ],
      payments: [
        { method: 'ポイント利用', amount: 100, source_text: 'ポイント利用 -100', source_line_index: 41 },
        { method: 'credit', amount: 900 }
      ]
    )

    aggregate_failures do
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(-100)
      expect(result.dig(:computed, :final_payment_total)).to eq(900)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_000)
      expect(result[:blocking_inconsistencies]).to include(:payment_amount_mismatch)
      expect(result[:review_reasons]).to include('payment_amount_mismatch')
      expect(result[:needs_review]).to be(true)
    end
  end

  it 'gift card paymentがdiscountとしても抽出された場合は購入合計を減らさない' do
    result = call_amount_engine(
      receipt: { total_amount: 1_000 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        {
          kind: 'receipt_discount', sign: 'discount', amount: 500, source_text: 'ギフトカード 500',
          source_line_index: 12, source_span_start: 7, source_span_end: 10, source: 'ocr'
        }
      ],
      payments: [
        {
          method: 'gift_card', amount: 500, source_text: 'ギフトカード 500',
          source_line_index: 12, source_span_start: 7, source_span_end: 10
        },
        { method: 'credit', amount: 500 }
      ]
    )

    aggregate_failures do
      expect(result.dig(:computed, :purchase_total)).to eq(1_000)
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(0)
      expect(result.dig(:computed, :final_payment_total)).to eq(1_000)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_000)
      expect(result[:blocking_inconsistencies]).to be_empty
      expect(result[:needs_review]).to be(false)
    end
  end

  it 'couponとpayment discountが別行なら購入調整と支払調整をそれぞれ一度だけ反映する' do
    result = call_amount_engine(
      receipt: { total_amount: 900 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        { kind: 'coupon', sign: 'discount', amount: 100, source_text: 'クーポン -100', source_line_index: 20, source: 'ocr' },
        { kind: 'receipt_discount', sign: 'discount', amount: 100, source_text: 'payment discount -100', source_line_index: 21, source: 'ocr' }
      ],
      payments: [
        { method: 'credit', amount: 800 }
      ]
    )

    aggregate_failures do
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(-100)
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(-100)
      expect(result.dig(:computed, :purchase_total)).to eq(900)
      expect(result.dig(:computed, :final_payment_total)).to eq(800)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(800)
      expect(result[:blocking_inconsistencies]).to be_empty
      expect(result[:needs_review]).to be(false)
    end
  end

  it '外税レシートではexternal_tax候補を採用する' do
    result = call_amount_engine(
      receipt: { subtotal_amount: 1_000, tax_amount: 100, total_amount: 1_100, tax_rate: BigDecimal('0.10') },
      items: [
        { line_total: 400, tax_rate: BigDecimal('0.10') },
        { line_total: 600, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.10'), net_amount: 1_000, amount: 100, description: '外税10%' }
      ],
      payments: [
        { method: 'cash', amount: 1_100 }
      ]
    )

    aggregate_failures do
      # 検算: 税抜明細 400 + 600 = 1,000、外税10% = 100、税込合計 1,100。
      expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100, tax_rate: BigDecimal('0.10'))
      expect(result.dig(:amount_engine, :selected_basis)).to eq('external_tax_from_receipt')
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_100)
      expect(result[:needs_review]).to be(false)
    end
  end

  it '現金と電子マネーの複数支払をfinal_payment_totalと照合する' do
    result = call_amount_engine(
      receipt: { subtotal_amount: 1_061, tax_amount: 100, total_amount: 1_161 },
      items: [
        { line_total: 150, tax_rate: BigDecimal('0.08') },
        { line_total: 130, tax_rate: BigDecimal('0.08') },
        { line_total: 881, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 280, amount: 20, description: '8%対象' },
        { rate: BigDecimal('0.10'), net_amount: 881, amount: 80, description: '10%対象' }
      ],
      payments: [
        { method: 'cash', amount: 500 },
        { method: '電子マネー', amount: 661 }
      ]
    )

    aggregate_failures do
      # 検算: 購入合計 1,161、支払合計 500 + 661 = 1,161。
      expect(result[:resolved]).to include(subtotal: 1_061, tax: 100, total: 1_161)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_161)
      expect(result.dig(:computed, :final_payment_total)).to eq(1_161)
      expect(result[:blocking_inconsistencies]).to be_empty
    end
  end

  it 'VAT/GSTの任意税率候補を扱う' do
    vat = call_amount_engine(
      receipt: { subtotal_amount: 100, tax_amount: 20, total_amount: 120 },
      items: [
        { line_total: 120, tax_rate: BigDecimal('0.20') }
      ],
      tax_details: [
        { rate: BigDecimal('0.20'), net_amount: 120, amount: 20, description: 'VAT included 20%' }
      ],
      payments: [
        { method: 'card', amount: 120 }
      ]
    )

    gst = call_amount_engine(
      receipt: { subtotal_amount: 1_000, tax_amount: 50, total_amount: 1_050 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0.05') }
      ],
      tax_details: [
        { rate: BigDecimal('0.05'), net_amount: 1_000, amount: 50, description: 'GST exclusive 5%' }
      ],
      payments: [
        { method: 'card', amount: 1_050 }
      ]
    )

    aggregate_failures do
      # 検算: VAT内税 120 * 20 / 120 = 20、税抜100。
      expect(vat[:resolved]).to include(subtotal: 100, tax: 20, total: 120)
      # 検算: GST外税 1,000 * 5% = 50、税込1,050。
      expect(gst[:resolved]).to include(subtotal: 1_000, tax: 50, total: 1_050)
      expect(gst.dig(:amount_engine, :selected_basis)).to eq('external_tax_from_receipt')
    end
  end

  it '支払合計がfinal_payment_totalと不一致ならblocking reviewにする' do
    result = call_amount_engine(
      receipt: { total_amount: 1_000 },
      items: [
        { line_total: 1_000 }
      ],
      payments: [
        { method: 'cash', amount: 900 }
      ]
    )

    expect(result[:blocking_inconsistencies]).to include(:payment_amount_mismatch)
    expect(result[:review_reasons]).to include('payment_amount_mismatch')
    expect(result[:needs_review]).to be(true)
  end

  it 'analysisでは支払合計がfinal_payment_totalを上回るだけならpayment_amount_mismatchにしない' do
    result = call_amount_engine(
      receipt: { total_amount: 1_000 },
      items: [
        { line_total: 1_000 }
      ],
      payments: [
        { method: 'cash', amount: 1_100 }
      ]
    )

    aggregate_failures do
      # 検算: analysisではお預かり等が支払行に入った可能性を考慮し、過払いだけではreview理由にしない。
      expect(result.dig(:computed, :final_payment_total)).to eq(1_000)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_100)
      expect(result[:blocking_inconsistencies]).not_to include(:payment_amount_mismatch)
      expect(result[:review_reasons]).not_to include('payment_amount_mismatch')
      expect(result.dig(:amount_engine, :selected_candidate, :evidence)).to include(
        include(
          source: 'receipt_payments',
          payment_amount_sum: 1_100,
          final_payment_total: 1_000,
          payment_delta: 100,
          payment_amount_mismatch_suppressed: true,
          suppressed_reason: 'tendered_like_overpayment'
        )
      )
      expect(result[:needs_review]).to be(false)
    end
  end

  it 'analysisでも非現金の単一支払過払いはblocking reviewにする' do
    aggregate_failures 'non-cash overpayments' do
      %w[credit e_money qr_payment gift_card].each do |method|
        result = call_amount_engine(
          receipt: { total_amount: 1_000 },
          items: [
            { line_total: 1_000 }
          ],
          payments: [
            { method: method, amount: 1_100 }
          ]
        )

        # 検算: 実支払額1,000円に対して、非現金決済で1,100円の支払行がある。
        # 現金お預かりとは異なり、過払い方向でも支払額不一致として確認対象にする。
        expect(result.dig(:computed, :final_payment_total)).to eq(1_000)
        expect(result.dig(:computed, :payment_amount_sum)).to eq(1_100)
        expect(result[:blocking_inconsistencies]).to include(:payment_amount_mismatch)
        expect(result[:review_reasons]).to include('payment_amount_mismatch')
        expect(result[:needs_review]).to be(true)
      end
    end
  end

  it 'analysisでも複数支払の過払いは現金お預かり扱いでsuppressしない' do
    result = call_amount_engine(
      receipt: { total_amount: 1_000 },
      items: [
        { line_total: 1_000 }
      ],
      payments: [
        { method: 'cash', amount: 500 },
        { method: 'e_money', amount: 600 }
      ]
    )

    aggregate_failures do
      # 検算: 実支払額1,000円に対して、複数支払合計は1,100円。
      # 単一の現金お預かり行とは判定できないため確認対象にする。
      expect(result.dig(:computed, :final_payment_total)).to eq(1_000)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_100)
      expect(result[:blocking_inconsistencies]).to include(:payment_amount_mismatch)
      expect(result[:review_reasons]).to include('payment_amount_mismatch')
      expect(result[:needs_review]).to be(true)
    end
  end

  it 'analysisでもexact final payment lineとお預かり行が併存する場合は過払いをsuppressしない' do
    result = call_amount_engine(
      receipt: { total_amount: 1_000 },
      items: [
        { line_total: 1_000 }
      ],
      payments: [
        { method: 'cash', amount: 1_000 },
        { method: 'cash_tendered', amount: 1_100 }
      ]
    )

    aggregate_failures do
      # 検算: 1,000円の実支払行がすでにあり、1,100円のお預かりらしき行も入っている。
      # exact final payment lineがある場合は二重抽出疑いとして確認対象にする。
      expect(result.dig(:computed, :final_payment_total)).to eq(1_000)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(2_100)
      expect(result[:blocking_inconsistencies]).to include(:payment_amount_mismatch)
      expect(result[:review_reasons]).to include('payment_amount_mismatch')
      expect(result[:needs_review]).to be(true)
    end
  end

  it '支払合計がfinal_payment_totalを上回る過払いもblocking reviewにする' do
    result = call_amount_engine(
      receipt: { total_amount: 1_000 },
      items: [
        { line_total: 1_000 }
      ],
      payments: [
        { method: 'cash', amount: 1_100 }
      ],
      context: :manual
    )

    aggregate_failures do
      # 検算: 実支払額 1,000 に対し支払合計 1,100 なので100円過払い。
      expect(result.dig(:computed, :final_payment_total)).to eq(1_000)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_100)
      expect(result[:blocking_inconsistencies]).to include(:payment_amount_mismatch)
      expect(result[:needs_review]).to be(true)
    end
  end

  it 'edit_saveでは過払い方向でもpayment_amount_mismatchをsuppressしない' do
    result = call_amount_engine(
      receipt: { total_amount: 1_000 },
      items: [
        { line_total: 1_000 }
      ],
      payments: [
        { method: 'cash', amount: 1_100 }
      ],
      context: :edit_save
    )

    aggregate_failures do
      # 検算: ユーザー編集保存では、OCRお預かりfallbackではなく明示入力として扱う。
      expect(result.dig(:computed, :final_payment_total)).to eq(1_000)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_100)
      expect(result[:blocking_inconsistencies]).to include(:payment_amount_mismatch)
      expect(result[:needs_review]).to be(true)
    end
  end

  it 'resolved totalは購入合計、computed final_payment_totalは支払照合用として分けて返す' do
    result = call_amount_engine(
      receipt: { total_amount: 1_900 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0') },
        { line_total: 1_000, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        { kind: 'coupon', sign: 'discount', amount: 100, source: 'ocr' },
        { kind: 'point_usage', sign: 'discount', amount: 300, source: 'ocr' }
      ],
      payments: [
        { method: 'credit', amount: 1_600 }
      ]
    )

    aggregate_failures do
      # 検算: 商品合計2,000、クーポン -100 は購入合計へ反映し1,900。
      # ポイント利用 -300 は支払調整なので final_payment_total は1,600。
      expect(result[:resolved]).to include(total: 1_900)
      expect(result.dig(:computed, :purchase_total)).to eq(1_900)
      expect(result.dig(:computed, :final_payment_total)).to eq(1_600)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_600)
      expect(result[:needs_review]).to be(false)
    end
  end

  it '全candidateがhard rejectされた場合はreview draftを残しつつ自動完了不可にする' do
    rejected_candidate = Amounts::Candidate.new(
      candidate_id: 'spec/all_rejected',
      basis: 'items_as_tax_included',
      subtotal: 1_000,
      tax: 100,
      purchase_total: 1_100,
      final_payment_total: 1_100,
      tax_details: [],
      tax_rate_groups: [ { rate: BigDecimal('0.10'), gross: 1_100, net: 1_000, tax: 100 } ],
      hard_reject_reasons: [ :tax_detail_mismatch ],
      computed_items: [ { price: 1_100, line_total: 1_100, quantity: BigDecimal('1') } ],
      source: :amount_engine
    )

    generator = instance_double(Amounts::CandidateGenerator, call: [ rejected_candidate ])
    allow(Amounts::CandidateGenerator).to receive(:new).and_return(generator)

    result = call_amount_engine(
      receipt: {},
      items: [
        { line_total: 1_100, tax_rate: BigDecimal('0.10') }
      ]
    )

    aggregate_failures do
      expect(result[:resolved]).to include(total: 1_100)
      expect(result[:needs_review]).to be(true)
      expect(result[:safe_to_auto_complete]).to be(false)
      expect(result[:selected_candidate_status]).to eq('rejected')
      expect(result.dig(:amount_engine, :no_safe_candidate)).to be(true)
      expect(result.dig(:amount_engine, :selected_candidate_status)).to eq('rejected')
      expect(result[:review_reasons]).to include('tax_detail_mismatch')
      expect(result[:blocking_inconsistencies]).to include(:tax_detail_mismatch)
    end
  end

  it 'printed tax details netが完全整合しても別basisのexact候補があれば税込税抜確認を残す' do
    printed_net_candidate = Amounts::Candidate.new(
      candidate_id: 'printed_tax_details_net/floor',
      basis: 'printed_tax_details_net',
      subtotal: 1_000,
      tax: 100,
      purchase_total: 1_100,
      final_payment_total: 1_100,
      tax_details: [
        { rate: BigDecimal('0.10'), net_amount: 1_000, amount: 100 }
      ],
      tax_rate_groups: [
        { rate: BigDecimal('0.10'), gross: 1_100, net: 1_000, tax: 100 }
      ],
      warnings: [ :price_tax_inclusion_uncertain ],
      computed_items: [
        { price: 1_100, line_total: 1_100, quantity: BigDecimal('1'), tax_rate: BigDecimal('0.10') }
      ],
      source: :amount_engine
    )
    included_candidate = Amounts::Candidate.new(
      candidate_id: 'items_as_tax_included/floor/per_receipt',
      basis: 'items_as_tax_included',
      subtotal: 1_000,
      tax: 100,
      purchase_total: 1_100,
      final_payment_total: 1_100,
      tax_details: [
        { rate: BigDecimal('0.10'), net_amount: 1_000, amount: 100 }
      ],
      tax_rate_groups: [
        { rate: BigDecimal('0.10'), gross: 1_100, net: 1_000, tax: 100 }
      ],
      computed_items: [
        { price: 1_100, line_total: 1_100, quantity: BigDecimal('1'), tax_rate: BigDecimal('0.10') }
      ],
      source: :amount_engine
    )

    generator = instance_double(Amounts::CandidateGenerator, call: [ printed_net_candidate, included_candidate ])
    allow(Amounts::CandidateGenerator).to receive(:new).and_return(generator)

    result = call_amount_engine(
      receipt: { subtotal_amount: 1_000, tax_amount: 100, total_amount: 1_100 },
      items: [
        { line_total: 1_100, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.10'), net_amount: 1_000, amount: 100, description: '外税10%' }
      ],
      payments: [
        { method: 'cash', amount: 1_100 }
      ]
    )

    aggregate_failures do
      expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('printed_tax_details_net/floor')
      expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain, :competing_exact_basis_candidate)
      expect(result[:review_reasons]).to include('price_tax_inclusion_uncertain', 'competing_exact_basis_candidate')
      expect(result[:needs_review]).to be(true)
    end
  end

  it '複数税率かつ印字tax detailsありの購入調整tax_rate nilは税配賦不確実としてreview対象にする' do
    result = call_amount_engine(
      receipt: { subtotal_amount: 800, tax_amount: 78, total_amount: 878 },
      items: [
        { line_total: 216, tax_rate: BigDecimal('0.08') },
        { line_total: 162, tax_rate: BigDecimal('0.08') },
        { line_total: 550, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 378, amount: 28, description: '8%対象' },
        { rate: BigDecimal('0.10'), net_amount: 550, amount: 50, description: '10%対象' }
      ],
      adjustments: [
        { kind: 'receipt_discount', sign: 'discount', amount: 50, source: 'ocr' }
      ],
      payments: [
        { method: 'cash', amount: 878 }
      ]
    )

    aggregate_failures do
      # 検算: 8%/10%の対象額が印字されているが、購入値引き50円の税率配賦が不明。
      # adjustment_tax_rate_missingをwarning-onlyで済ませず、税配賦不確実として確認対象にする。
      expect(result[:warning_inconsistencies]).to include(:adjustment_tax_rate_missing)
      expect(result[:review_reasons]).to include('purchase_adjustment_tax_allocation_uncertain')
      expect(result[:needs_review]).to be(true)
    end
  end

  it '単一positive税率と非課税が混在する購入調整tax_rate nilは税配賦不確実としてreview対象にする' do
    result = call_amount_engine(
      receipt: { total_amount: 1_500 },
      items: [
        { line_total: 1_100, tax_rate: BigDecimal('0.10') },
        { line_total: 500, tax_rate: BigDecimal('0') }
      ],
      adjustments: [
        { kind: 'coupon', sign: 'discount', amount: 100, source: 'ocr' }
      ],
      payments: [
        { method: 'cash', amount: 1_500 }
      ]
    )

    aggregate_failures do
      # 検算: positive税率は10%のみだが非課税対象もあるため、
      # 購入値引き100円を課税/非課税のどちらへ配賦するか一意に決めない。
      expect(result.dig(:computed, :purchase_total)).to eq(1_500)
      expect(result[:warning_inconsistencies]).to include(:adjustment_tax_rate_missing)
      expect(result[:review_reasons]).to include('purchase_adjustment_tax_allocation_uncertain')
      expect(result[:needs_review]).to be(true)
      expect(result[:safe_to_auto_complete]).to be(false)
    end
  end

  it 'SystemSettingsの税抜補正設定が取得不能ならanalysisでは税込補正候補を生成しない' do
    [ SystemSettings::UnknownKeyError, SystemSettings::ValidationError ].each do |error_class|
      allow(SystemSettings).to receive(:enabled?).and_call_original
      allow(SystemSettings).to receive(:enabled?)
        .with(ReceiptAmountService::TAX_EXCLUDED_PRICE_CONVERSION_SETTING_KEY)
        .and_raise(error_class, 'setting unavailable')

      result = call_amount_engine(
        receipt: {
          subtotal_amount: 1_390,
          tax_amount: 125,
          total_amount: 1_515
        },
        items: [
          { price: 130, quantity: 1, quantity_unit_code: 'each', original_line_total: 130, line_total: 130, tax_rate: BigDecimal('0.08') },
          { price: 140, quantity: 1, quantity_unit_code: 'each', original_line_total: 140, line_total: 140, tax_rate: BigDecimal('0.08') },
          { price: 300, quantity: 1, quantity_unit_code: 'each', original_line_total: 300, line_total: 300, tax_rate: BigDecimal('0.10') },
          { price: 490, quantity: 1, quantity_unit_code: 'each', original_line_total: 490, line_total: 490, tax_rate: BigDecimal('0.10') },
          { price: 50, quantity: 1, quantity_unit_code: 'each', original_line_total: 50, line_total: 50, tax_rate: BigDecimal('0') }
        ],
        tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 270, amount: 21, description: '8%対象' },
          { rate: BigDecimal('0.10'), net_amount: 300, amount: 30, description: '小計（税抜10%）' },
          { rate: BigDecimal('0.10'), net_amount: 820, amount: 74, description: '10%対象' }
        ],
        adjustments: [
          {
            kind: 'other',
            label: 'キャッシュレス還元額',
            source_text: 'キャッシュレス還元額 -22',
            sign: 'discount',
            amount: 22,
            source: 'ocr'
          }
        ],
        payments: [
          { method: 'nanaco', amount: 1_139 }
        ]
      )

      aggregate_failures error_class.name do
        # 検算: 設定取得不能時は安全側として税込補正をOFF相当に倒し、
        # items_as_tax_excluded系候補を生成しない。
        expect(result.dig(:amount_engine, :candidates).map { |candidate| candidate[:candidate_id] }.grep(%r{\Aitems_as_tax_excluded/})).to be_empty
        expect(result.dig(:amount_engine, :selected_candidate, :computed_items).map { |item| item[:price] }).to eq([ 130, 140, 300, 490, 50 ])
      end
    end
  end

  it 'same-rate mixed探索がitem数上限に到達したらsilent completedにしない' do
    result = call_amount_engine(
      receipt: {
        subtotal_amount: 200,
        tax_amount: 20,
        total_amount: 220
      },
      items: Array.new(21) do
        { line_total: 10, tax_rate: BigDecimal('0.10') }
      end,
      tax_details: [
        { rate: BigDecimal('0.10'), net_amount: 200, amount: 20, description: '10%対象' }
      ]
    )

    aggregate_failures do
      expect(result[:warning_inconsistencies]).to include(:mixed_basis_search_truncated)
      expect(result[:review_reasons]).to include('mixed_basis_search_truncated')
      expect(result[:needs_review]).to be(true)
    end
  end
end
