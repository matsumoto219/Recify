require 'rails_helper'

RSpec.describe ReceiptAmountService do
  def calculation_settings(tax: 'floor', discount: 'round', scope: 'per_tax_rate_group', adjustment: 'gross')
    {
      'schema_version' => 1,
      'tax_rounding_mode' => { 'value' => tax, 'origin' => 'manual' },
      'discount_rounding_mode' => { 'value' => discount, 'origin' => 'manual' },
      'tax_rounding_scope' => { 'value' => scope, 'origin' => 'legacy_record' },
      'purchase_adjustment_tax_inclusion' => { 'value' => adjustment, 'origin' => 'manual' }
    }
  end

  def count_item(basis: 'gross', price: 100, quantity: 2, **attributes)
    {
      pricing_source_kind: 'count_unit_price',
      price: price,
      quantity: quantity,
      quantity_unit_code: 'each',
      input_tax_inclusion: basis,
      tax_rate: '0.10'
    }.merge(attributes)
  end

  def calculate(items:, settings: calculation_settings, context: :manual, receipt: {}, adjustments: [], **options)
    described_class.call(
      receipt: receipt.merge(calculation_settings: settings),
      receipt_items: items,
      receipt_tax_details: [],
      receipt_adjustments: adjustments,
      context: context,
      **options
    )
  end

  describe '明示されたレシート条件と明細税区分' do
    %i[manual edit_save].product(%w[gross net]).each do |context, basis|
      it "#{context}のcount #{basis}は入力sourceと税込投影を分離する" do
        result = calculate(items: [ count_item(basis: basis) ], context: context)

        aggregate_failures do
          expect(result[:resolved]).to include(total: basis == 'net' ? 220 : 200, tax: basis == 'net' ? 20 : 18)
          expect(result.dig(:computed, :source_items).sole).to include(price: 100, line_total: 200, input_tax_inclusion: basis)
          expect(result.dig(:computed, :items).sole).to include(price: 100, line_total: basis == 'net' ? 220 : 200)
          expect(result[:selected_candidate_status]).to eq('accepted')
          expect(result[:needs_review]).to be(false)
        end
      end
    end

    it 'explicit netは数量を掛けずreference diagnosticのbasisを入力basisとして使用しない' do
      [ 3, 4 ].each do |quantity|
        result = calculate(
          items: [
            {
              pricing_source_kind: 'explicit_line_total',
              input_tax_inclusion: 'net',
              line_total: 500,
              quantity: quantity,
              quantity_unit_code: 'each',
              tax_rate: '0.10',
              reference_price_tax_inclusion: 'gross'
            }
          ]
        )

        expect(result[:resolved]).to include(total: 550, tax: 50)
        expect(result.dig(:computed, :source_items).sole[:line_total]).to eq(500)
      end
    end

    it 'manual reference netは固定HALF_UPのsourceへ絶対額割引を一度だけ適用する' do
      [ [ 250, 253 ], [ 500, 528 ], [ 250, 253 ] ].each do |quantity, total|
        result = calculate(
          items: [
            {
              pricing_source_kind: 'reference_quantity_price',
              reference_price_amount: '100',
              reference_quantity: '100',
              reference_quantity_unit_code: 'gram',
              quantity: quantity.to_s,
              quantity_unit_code: 'gram',
              reference_price_tax_inclusion: 'net',
              discount_amount: 20,
              tax_rate: '0.10'
            }
          ]
        )

        expect(result[:resolved][:total]).to eq(total)
        expect(result.dig(:computed, :source_items).sole).to include(
          original_line_total: quantity,
          discount_amount: 20,
          line_total: quantity - 20
        )
      end
    end

    it 'group丸めの正式合計と明細の税込参考額を区別して差を配賦しない' do
      items = Array.new(2) { count_item(basis: 'net', price: 19, quantity: 1) }
      per_item = calculate(items: items, settings: calculation_settings(scope: 'per_item'))
      per_group = calculate(items: items)

      aggregate_failures do
        expect(per_item[:resolved]).to include(total: 40, tax: 2)
        expect(per_group[:resolved]).to include(total: 41, tax: 3)
        expect(per_group.dig(:computed, :items).map { |item| item[:line_total] }).to eq([ 20, 20 ])
        expect(per_group.dig(:amount_engine, :selected_candidate, :rounding_scope)).to eq(:per_tax_rate_group)
      end
    end

    it '同じ税率のgross/netはそれぞれのbasisで丸める' do
      result = calculate(items: [ count_item(basis: 'net', price: 19, quantity: 1), count_item(price: 22, quantity: 1) ])

      expect(result[:resolved]).to include(total: 42, tax: 3, subtotal: 39)
      expect(result.dig(:computed, :item_amount_basis)).to eq(:mixed_by_tax_rate_group)
      expect(result[:needs_review]).to be(false)
    end

    it 'explicitの入力basisと異なるreference diagnosticを同じ金額として比較しない' do
      item = {
        pricing_source_kind: 'explicit_line_total',
        input_tax_inclusion: 'net',
        line_total: 500,
        quantity: '100',
        quantity_unit_code: 'gram',
        tax_rate: '0.10',
        reference_price_amount: '450',
        reference_quantity: '100',
        reference_quantity_unit_code: 'gram',
        reference_price_tax_inclusion: 'gross'
      }

      result = calculate(items: [ item ])
      expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
      expect(result[:resolved][:total]).to eq(550)

      same_basis = calculate(items: [ item.merge(reference_price_tax_inclusion: 'net') ])
      expect(same_basis[:inconsistencies]).to include(:item_total_mismatch)
    end

    it '送料のgross/netは明細basisから独立する' do
      adjustment = { amount: 11, sign: 'surcharge', kind: 'delivery_fee', tax_rate: '0.10' }
      net = calculate(items: [ count_item(basis: 'net', quantity: 1) ], adjustments: [ adjustment ])
      gross = calculate(items: [ count_item(quantity: 1) ], adjustments: [ adjustment ])

      expect(net[:resolved]).to include(total: 121, tax: 11)
      expect(gross[:resolved]).to include(total: 111, tax: 10)
    end

    it 'net購入調整はgross明細から独立して税額を加え、支払調整を課税しない' do
      result = calculate(
        items: [ count_item(quantity: 1) ],
        settings: calculation_settings(adjustment: 'net'),
        adjustments: [
          { amount: 10, sign: 'surcharge', kind: 'delivery_fee', tax_rate: '0.10' },
          { amount: 20, sign: 'discount', kind: 'point_usage', tax_rate: nil }
        ]
      )

      expect(result[:resolved]).to include(total: 111, tax: 10)
      expect(result.dig(:computed, :final_payment_total)).to eq(91)
    end

    it '購入調整があるときだけ明示的な調整basisを必須にする' do
      settings = calculation_settings.except('purchase_adjustment_tax_inclusion')
      expect(calculate(items: [ count_item ], settings: settings)[:resolved][:total]).to eq(200)

      expect do
        calculate(
          items: [ count_item ],
          settings: settings,
          adjustments: [
            { amount: 10, kind: 'delivery_fee', sign: 'surcharge', tax_rate: '0.10' }
          ]
        )
      end.to raise_error(ReceiptAmountService::InvalidItemSourceError)
    end

    it '保存済みper_receiptをgroup既定値へ変更しない' do
      result = calculate(items: [ count_item(basis: 'net', price: 19, quantity: 1) ], settings: calculation_settings(scope: 'per_receipt'))

      expect(result.dig(:amount_engine, :selected_candidate, :rounding_scope)).to eq(:per_receipt)
      expect(result[:resolved]).to include(total: 20, tax: 1)
    end

    it '異なる税率のgroupを合算してもbasisごとの税額が変わらない' do
      result = calculate(
        items: [
          count_item(basis: 'net', price: 19, quantity: 1),
          count_item(basis: 'net', price: 19, quantity: 1),
          count_item(price: 108, quantity: 1, tax_rate: '0.08')
        ]
      )

      expect(result[:resolved]).to include(total: 149, tax: 11, subtotal: 138)
      expect(result.dig(:computed, :tax_rate_groups).map { |group| group[:tax] }).to eq([ 3, 8 ])
    end

    it '税区分を切り替えても絶対額割引を自動換算しない' do
      net = calculate(items: [ count_item(basis: 'net', discount_amount: 20) ])
      gross = calculate(items: [ count_item(discount_amount: 20) ])

      expect(net[:resolved][:total]).to eq(198)
      expect(gross[:resolved][:total]).to eq(180)
      expect(net.dig(:computed, :source_items).sole[:discount_amount]).to eq(20)
      expect(gross.dig(:computed, :source_items).sole[:discount_amount]).to eq(20)
      expect(net.dig(:computed, :source_items).sole[:discount_rate]).to be_nil
      expect(gross.dig(:computed, :source_items).sole[:discount_rate]).to be_nil
    end

    it '保存済み丸めは現在の引数や候補scoreにかかわらず固定する' do
      result = calculate(
        items: [ count_item(basis: 'net', price: 19, quantity: 1, discount_rate: '0.05') ],
        settings: calculation_settings(tax: 'ceil', discount: 'floor', scope: 'per_item'),
        tax_rounding_mode: :floor,
        discount_rounding_mode: :ceil
      )

      expect(result[:rounding_mode]).to eq(tax: :ceil, discount: :floor)
      expect(result[:resolved]).to include(total: 21, tax: 2)
      expect(result.dig(:computed, :source_items).sole[:discount_amount]).to eq(0)
      expect(result.dig(:amount_engine, :candidates).map { |candidate| candidate[:rounding_scope] }.uniq).to eq([ :per_item ])
    end

    it '明示netの欠損税率をreceipt税率や0で補完しない' do
      expect do
        calculate(items: [ count_item(basis: 'net', tax_rate: nil) ], receipt: { tax_rate: '0.10' })
      end.to raise_error(ReceiptAmountService::InvalidItemSourceError)

      result = calculate(items: [ count_item(basis: 'net', tax_rate: '0') ])
      expect(result[:resolved]).to include(total: 200, tax: 0)
    end

    it 'unknown・partialな計算条件は既定値へ黙って切り替えない' do
      [ {}, calculation_settings.merge('schema_version' => 2), calculation_settings.except('tax_rounding_scope') ].each do |settings|
        expect { calculate(items: [ count_item ], settings: settings) }
          .to raise_error(ReceiptAmountService::InvalidItemSourceError)
      end
    end

    it '不正な明細税区分やlegacy modeへの税区分入力を受理しない' do
      [ count_item(basis: 'unknown'), count_item(basis: false), count_item(basis: nil), count_item(pricing_source_kind: nil) ].each do |item|
        expect { calculate(items: [ item ]) }.to raise_error(ReceiptAmountService::InvalidItemSourceError)
      end
    end

    it 'sourceと税込projectionの既存明細IDを保ち、新規明細へIDを発明しない' do
      result = calculate(items: [ count_item(id: '42', basis: 'net'), count_item ])

      [ :source_items, :items ].each do |key|
        expect(result.dig(:computed, key).map { |item| item[:id] }).to eq([ 42, nil ])
      end
      snapshot = described_class.calculation_profile_snapshot(result)
      snapshot.dig(:amount_engine, :selected_candidate, :computed_items).each do |item|
        expect(item).not_to have_key(:id)
      end
    end

    it '不正な既存明細IDを金額や行順から補完しない' do
      [ 0, -1, 1.5, true, '42x', '0', '9' * 30 ].each do |id|
        expect { calculate(items: [ count_item(id: id) ]) }.to raise_error(ReceiptAmountService::InvalidItemSourceError)
      end
    end

    it '明示basisに応じた候補名を使い古いレシート全体basisで誤表記しない' do
      net = calculate(items: [ count_item(basis: 'net') ], receipt: { item_amount_basis: 'line_total_as_recorded' })
      gross = calculate(items: [ count_item ], receipt: { item_amount_basis: 'line_total_as_net' })

      expect(net.dig(:amount_engine, :selected_basis)).to eq('items_as_tax_excluded')
      expect(gross.dig(:amount_engine, :selected_basis)).to eq('items_as_tax_included')
    end

    it 'legacy net sourceは保存後の再編集でもbasisを失わず、typed sourceを発明しない' do
      item = { price: 100, quantity: 2, quantity_unit_code: 'each', tax_rate: '0.10' }
      first = calculate(
        items: [ item ],
        context: :edit_save,
        receipt: { receipt_tax_basis: 'tax_added_to_subtotal', item_amount_basis: 'line_total_as_net' }
      )
      receipt = Receipt.new(
        calculation_settings: calculation_settings,
        amount_calculation_profile: described_class.calculation_profile_snapshot(first)
      )
      second = calculate(
        items: [ item.merge(quantity: 3) ],
        context: :edit_save,
        receipt: receipt.amount_source_semantics_for_edit.symbolize_keys
      )

      aggregate_failures do
        expect(first[:resolved][:total]).to eq(220)
        expect(second[:resolved][:total]).to eq(330)
        expect(receipt.amount_source_semantics_for_edit).to include(
          'receipt_tax_basis' => 'tax_added_to_subtotal',
          'item_amount_basis' => 'line_total_as_net'
        )
        expect(second.dig(:computed, :source_items).sole).to include(price: 100, line_total: 300)
        expect(second.dig(:computed, :source_items).sole[:pricing_source_kind]).to be_nil
        expect(second.dig(:computed, :source_items).sole[:input_tax_inclusion]).to be_nil
      end
    end

    it 'analysisは追加の入力条件から既存のwinnerや金額を変えない' do
      input = { total_amount: 200, subtotal_amount: 182, tax_amount: 18 }
      items = [ count_item.except(:input_tax_inclusion) ]
      existing = calculate(items: items, settings: nil, receipt: input, context: :analysis)
      added = calculate(items: [ count_item(basis: 'net') ], settings: calculation_settings(tax: 'ceil'), receipt: input, context: :analysis)

      expect(added).to eq(existing)
    end

    it '計算で入力sourceと設定を変更しない' do
      settings = calculation_settings
      items = [ count_item(basis: 'net', discount_amount: 20) ]
      original_settings = settings.deep_dup
      original_items = items.deep_dup

      calculate(items: items, settings: settings)

      expect(settings).to eq(original_settings)
      expect(items).to eq(original_items)
    end
  end
end
