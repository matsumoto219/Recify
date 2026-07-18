require 'rails_helper'

RSpec.describe 'Receipt amount edit consistency', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  def create_external_net_receipt
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      store_name: '金額編集テスト店',
      purchased_at: Time.zone.local(2026, 7, 1, 12, 0),
      payment_method: 'e_money',
      subtotal_amount: 742,
      tax_amount: 59,
      total_amount: 801,
      tax_rate: nil,
      amount_calculation_profile: external_net_profile
    )

    items = [
      [ '軽減税率商品A', 128, BigDecimal('0.08') ],
      [ '軽減税率商品B', 198, BigDecimal('0.08') ],
      [ '軽減税率商品C', 115, BigDecimal('0.08') ],
      [ '軽減税率商品D', 298, BigDecimal('0.08') ],
      [ '標準税率商品', 3, BigDecimal('0.10') ]
    ].each_with_index.map do |(name, price, tax_rate), position|
      receipt.receipt_items.create!(
        confirmed_name: name,
        price: price,
        quantity: 1,
        quantity_unit_code: 'each',
        original_line_total: price,
        line_total: price,
        tax_rate: tax_rate,
        position_index: position,
        needs_review: false,
        review_reasons: []
      )
    end

    receipt.receipt_tax_details.create!(
      description: '8%対象',
      rate: BigDecimal('0.08'),
      net_amount: 739,
      amount: 59
    )
    receipt.receipt_tax_details.create!(
      description: '10%対象',
      rate: BigDecimal('0.10'),
      net_amount: 3,
      amount: 0
    )
    receipt.receipt_payments.create!(method: '電子マネー', amount: 801)

    [ receipt, items ]
  end

  def external_net_profile
    {
      'schema_version' => 1,
      'context' => 'analysis',
      'profile' => {
        'tax_rounding_mode' => 'floor',
        'discount_rounding_mode' => 'round',
        'receipt_tax_basis' => 'tax_added_to_subtotal',
        'item_amount_basis' => 'line_total_as_net',
        'tax_detail_amount_basis' => 'net'
      },
      'computed' => {
        'subtotal_amount' => 742,
        'tax_amount' => 59,
        'total_amount' => 801
      },
      'resolved' => {
        'subtotal_amount' => 742,
        'tax_amount' => 59,
        'total_amount' => 801
      },
      'amount_engine' => {
        'schema_version' => 1,
        'selected_candidate_id' => 'external_tax_from_receipt/floor',
        'selected_basis' => 'external_tax_from_receipt',
        'selected_candidate_status' => 'accepted',
        'candidates' => [
          {
            'candidate_id' => 'external_tax_from_receipt/floor',
            'subtotal' => 742,
            'tax' => 59,
            'purchase_total' => 801
          }
        ]
      }
    }
  end

  def create_mixed_basis_receipt
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 1_066,
      tax_amount: 95,
      total_amount: 1_161,
      amount_calculation_profile: {
        'schema_version' => 1,
        'context' => 'analysis',
        'profile' => {
          'tax_rounding_mode' => 'floor',
          'discount_rounding_mode' => 'round',
          'receipt_tax_basis' => 'total_includes_tax',
          'item_amount_basis' => 'mixed_by_tax_rate_group',
          'tax_detail_amount_basis' => 'gross'
        }
      }
    )
    items = [
      [ 140, BigDecimal('0.08') ],
      [ 151, BigDecimal('0.08') ],
      [ 330, BigDecimal('0.10') ],
      [ 490, BigDecimal('0.10') ],
      [ 50, BigDecimal('0') ]
    ].each_with_index.map do |(amount, tax_rate), position|
      receipt.receipt_items.create!(
        confirmed_name: "mixed item #{position}",
        price: amount,
        quantity: 1,
        quantity_unit_code: 'each',
        original_line_total: amount,
        line_total: amount,
        tax_rate: tax_rate,
        position_index: position,
        needs_review: false,
        review_reasons: []
      )
    end
    receipt.receipt_tax_details.create!(rate: BigDecimal('0.08'), net_amount: 270, amount: 21)
    receipt.receipt_tax_details.create!(rate: BigDecimal('0.10'), net_amount: 746, amount: 74)
    receipt.receipt_payments.create!(method: 'cash', amount: 1_161)

    [ receipt, items ]
  end

  def item_attributes(item, quantity: item.quantity, line_total: item.line_total)
    {
      id: item.id,
      confirmed_name: item.confirmed_name,
      category: item.category,
      price: item.price,
      quantity: quantity.to_s,
      quantity_unit_code: item.quantity_unit_code,
      product_code: item.product_code,
      tax_rate: item.tax_rate.to_d * 100,
      discount_rate: item.discount_rate&.*(100),
      original_line_total: item.original_line_total,
      line_total: line_total.to_s,
      position_index: item.position_index,
      _destroy: '0'
    }
  end

  def submit_first_quantity(receipt, items, quantity)
    current_items = items.map(&:reload)
    attributes = current_items.each_with_index.to_h do |item, index|
      line_total = index.zero? ? item.price * quantity : item.line_total
      [ index.to_s, item_attributes(item, quantity: (index.zero? ? quantity : item.quantity), line_total: line_total) ]
    end

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.reload.lock_version,
        receipt_items_attributes: attributes
      }
    }
  end

  def saved_amount_snapshot(receipt)
    receipt.reload
    first_item = receipt.receipt_items.order(:position_index).first

    {
      status: response.status,
      subtotal: receipt.subtotal_amount,
      tax: receipt.tax_amount,
      total: receipt.total_amount,
      quantity: first_item.quantity.to_i,
      first_price: first_item.price,
      first_original_line_total: first_item.original_line_total,
      first_line_total: first_item.line_total,
      receipt_tax_basis: receipt.amount_calculation_profile.dig('profile', 'receipt_tax_basis'),
      item_amount_basis: receipt.amount_calculation_profile.dig('profile', 'item_amount_basis'),
      tax_details: receipt.receipt_tax_details.order(:rate).map do |detail|
        [ detail.rate.to_s('F'), detail.net_amount, detail.amount ]
      end
    }
  end

  def expected_saved_snapshot(subtotal:, tax:, total:, quantity:, first_line_total:)
    {
      status: 302,
      subtotal: subtotal,
      tax: tax,
      total: total,
      quantity: quantity,
      first_price: 128,
      first_original_line_total: first_line_total,
      first_line_total: first_line_total,
      receipt_tax_basis: 'tax_added_to_subtotal',
      item_amount_basis: 'line_total_as_net',
      tax_details: [
        [ '0.08', quantity == 2 ? 867 : 739, quantity == 2 ? 69 : 59 ],
        [ '0.1', 3, 0 ]
      ]
    }
  end

  def rendered_item_attributes(document)
    document.css('[data-receipt-form-target="itemRow"]').each_with_index.filter_map do |row, index|
      id = row.at_css('input[name$="[id]"]')&.[]('value')
      next unless id

      [
        index.to_s,
        {
          id: id,
          confirmed_name: row.at_css('input[name$="[confirmed_name]"]')&.[]('value'),
          price: row.at_css('[data-receipt-form-target="priceInput"]')&.[]('value'),
          quantity: row.at_css('[data-receipt-form-target="quantityInput"]')&.[]('value'),
          quantity_unit_code: selected_option_value(row, '[data-receipt-form-target="quantityUnitInput"]'),
          tax_rate: row.at_css('[data-receipt-form-target="taxRateInput"]')&.[]('value'),
          discount_rate: row.at_css('[data-receipt-form-target="discountRateInput"]')&.[]('value'),
          original_line_total: row.at_css('[data-receipt-form-target="originalLineTotalInput"]')&.[]('value'),
          line_total: row.at_css('[data-receipt-form-target="lineTotalInput"]')&.[]('value'),
          _destroy: '0'
        }
      ]
    end.to_h
  end

  def selected_option_value(document, selector)
    select = document.at_css(selector)
    return unless select

    select.at_css('option[selected]')&.[]('value') || select.at_css('option')&.[]('value')
  end

  def rendered_edit_snapshot(document, item_id:)
    form = document.at_css('[data-controller~="receipt-form"]')
    first_item = rendered_item_attributes(document).values.find { |item| item[:id].to_s == item_id.to_s }

    {
      status: response.status,
      basis: form['data-receipt-form-receipt-tax-basis-value'],
      first_price: first_item[:price].to_i,
      first_quantity: first_item[:quantity],
      first_line_total: first_item[:line_total].to_i
    }
  end

  def rendered_values_in_item_order(rendered_items, items, field)
    rendered_by_id = rendered_items.values.index_by { |item| item[:id].to_s }
    items.map { |item| rendered_by_id.fetch(item.id.to_s).fetch(field) }
  end

  def forced_external_result
    gross_items = [ 138, 213, 124, 321, 3 ].map do |amount|
      {
        quantity: BigDecimal('1'),
        price: amount,
        original_line_total: amount,
        line_total: amount,
        discount_amount: nil,
        discount_rate: nil
      }
    end

    {
      computed: {
        items: gross_items,
        subtotal: 742,
        tax: 59,
        total: 801,
        adjusted_item_total: 742,
        purchase_total: 801,
        purchase_adjustment_total: 0,
        payment_adjustment_total: 0,
        final_payment_total: 801,
        payment_amount_sum: 801,
        receipt_tax_basis: :tax_added_to_subtotal,
        item_amount_basis: :line_total_as_net
      },
      resolved: { subtotal: 742, tax: 59, total: 801, tax_rate: nil },
      tax_details: [
        { description: '8%対象', rate: BigDecimal('0.08'), net_amount: 739, amount: 59 },
        { description: '10%対象', rate: BigDecimal('0.10'), net_amount: 3, amount: 0 }
      ],
      review_reasons: [],
      warning_reasons: [],
      inconsistencies: [],
      safe_to_auto_complete: true,
      selected_candidate_status: 'accepted',
      context: :edit_save,
      rounding_mode: { tax: :floor, discount: :round },
      calculation_profile: {
        tax_rounding_mode: :floor,
        discount_rounding_mode: :round,
        receipt_tax_basis: :tax_added_to_subtotal,
        item_amount_basis: :line_total_as_net
      }
    }
  end

  it '税額0円の小額groupを含む保存済みexternal net basisを編集フォームへ渡す' do
    receipt, = create_external_net_receipt

    get edit_receipt_path(receipt)

    document = Nokogiri::HTML(response.body)
    form = document.at_css('[data-controller~="receipt-form"]')

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(receipt.receipt_tax_basis_for_form).to eq('external')
      expect(form['data-receipt-form-receipt-tax-basis-value']).to eq('external')
    end
  end

  it 'staleなreceipt数値を外しても保存済みsource semanticsをAmount結果へ維持する' do
    receipt, items = create_external_net_receipt
    observed_calls = []

    allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **arguments|
      result = original.call(**arguments)
      observed_calls << { arguments: arguments.deep_dup, result: result.deep_dup }
      result
    end

    submit_first_quantity(receipt, items, 2)

    calculation = observed_calls.last
    amount_input = calculation.fetch(:arguments).fetch(:receipt).with_indifferent_access
    amount_result = calculation.fetch(:result)
    serialized_calculation_input = calculation.fetch(:arguments).to_json
    saved_profile = receipt.reload.amount_calculation_profile['profile'] || {}

    aggregate_failures do
      expect(amount_input).not_to have_key(:subtotal_amount)
      expect(amount_input).not_to have_key(:tax_amount)
      expect(amount_input).not_to have_key(:total_amount)
      expect(amount_input).not_to have_key(:tax_rate)
      expect(calculation.fetch(:arguments).fetch(:receipt_tax_details)).to eq([])
      expect(serialized_calculation_input).to include(
        '"receipt_tax_basis":"tax_added_to_subtotal"',
        '"item_amount_basis":"line_total_as_net"'
      )
      expect(serialized_calculation_input).not_to include('"computed"', '"resolved"', '"candidates"')
      expect(amount_result.dig(:computed, :receipt_tax_basis)).to eq(:tax_added_to_subtotal)
      expect(amount_result.dig(:computed, :item_amount_basis)).to eq(:line_total_as_net)
      expect(amount_result.dig(:resolved, :subtotal)).to eq(870)
      expect(amount_result.dig(:resolved, :tax)).to eq(69)
      expect(amount_result.dig(:resolved, :total)).to eq(939)
      expect(saved_profile['receipt_tax_basis']).to eq('tax_added_to_subtotal')
      expect(saved_profile['item_amount_basis']).to eq('line_total_as_net')
    end
  end

  it 'mixed basisは計算時だけrecordedへ投影し、編集保存後のprovenanceに保持する' do
    receipt, items = create_mixed_basis_receipt

    submit_first_quantity(receipt, items, 1)
    receipt.reload

    aggregate_failures do
      expect(response).to have_http_status(:redirect)
      expect(receipt.attributes).to include(
        'subtotal_amount' => 1_066,
        'tax_amount' => 95,
        'total_amount' => 1_161
      )
      expect(receipt.amount_calculation_profile.dig('profile', 'item_amount_basis')).to eq('mixed_by_tax_rate_group')
      expect(receipt.amount_source_semantics_for_edit).to include(
        'receipt_tax_basis' => 'total_includes_tax',
        'item_amount_basis' => 'mixed_by_tax_rate_group'
      )
    end
  end

  it 'source_textだけが示すpayment adjustmentを編集保存後も購入金額から分離する' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 100,
      tax_amount: 0,
      total_amount: 100,
      amount_calculation_profile: {
        'profile' => {
          'tax_rounding_mode' => 'floor',
          'discount_rounding_mode' => 'round',
          'receipt_tax_basis' => 'total_includes_tax',
          'item_amount_basis' => 'line_total_as_recorded'
        }
      }
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '商品',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 100,
      line_total: 100,
      tax_rate: 0,
      needs_review: false,
      review_reasons: []
    )
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'receipt_discount',
      label: '還元額',
      amount: 22,
      sign: 'discount',
      source: 'ai',
      source_text: 'キャッシュレス還元額 -22',
      needs_review: false
    )
    receipt.receipt_payments.create!(method: 'cash', amount: 78)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: { '0' => item_attributes(item) },
        receipt_adjustments_attributes: {
          '0' => {
            id: adjustment.id,
            kind: adjustment.kind,
            label: adjustment.label,
            amount: adjustment.amount,
            sign: adjustment.sign,
            tax_rate: '',
            _destroy: '0'
          }
        }
      }
    }
    receipt.reload

    aggregate_failures do
      expect(response).to have_http_status(:redirect)
      expect(receipt.attributes).to include(
        'subtotal_amount' => 100,
        'tax_amount' => 0,
        'total_amount' => 100
      )
      expect(receipt.amount_calculation_profile.fetch('computed')).to include(
        'total_amount' => 100,
        'payment_adjustment_total' => -22,
        'final_payment_total' => 78
      )
      expect(adjustment.reload.source_text).to eq('キャッシュレス還元額 -22')
    end
  end

  it 'adjustment labelをpayment分類へ変更するとserver保存も同じeffectを使う' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 90,
      tax_amount: 0,
      total_amount: 90,
      amount_calculation_profile: {
        'profile' => {
          'tax_rounding_mode' => 'floor',
          'discount_rounding_mode' => 'round',
          'receipt_tax_basis' => 'total_includes_tax',
          'item_amount_basis' => 'line_total_as_recorded'
        }
      }
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '商品',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 100,
      line_total: 100,
      tax_rate: 0,
      needs_review: false,
      review_reasons: []
    )
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'receipt_discount',
      label: '通常値引き',
      amount: 10,
      sign: 'discount',
      source: 'manual',
      needs_review: false
    )
    receipt.receipt_payments.create!(method: 'cash', amount: 90)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: { '0' => item_attributes(item) },
        receipt_adjustments_attributes: {
          '0' => {
            id: adjustment.id,
            kind: adjustment.kind,
            label: 'キャッシュレス還元',
            amount: adjustment.amount,
            sign: adjustment.sign,
            tax_rate: '',
            _destroy: '0'
          }
        }
      }
    }
    receipt.reload

    aggregate_failures do
      expect(response).to have_http_status(:redirect)
      expect(receipt.attributes).to include(
        'subtotal_amount' => 100,
        'tax_amount' => 0,
        'total_amount' => 100
      )
      expect(receipt.amount_calculation_profile.fetch('computed')).to include(
        'total_amount' => 100,
        'payment_adjustment_total' => -10,
        'final_payment_total' => 90
      )
    end
  end

  it 'discount rateを変更して元へ戻す保存往復でも初期金額へ復帰する' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 1_000,
      tax_amount: 100,
      total_amount: 1_100,
      amount_calculation_profile: {
        'schema_version' => 1,
        'context' => 'analysis',
        'profile' => {
          'tax_rounding_mode' => 'floor',
          'discount_rounding_mode' => 'round',
          'receipt_tax_basis' => 'tax_added_to_subtotal',
          'item_amount_basis' => 'line_total_as_net'
        }
      }
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '割引対象商品',
      price: 1_000,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 1_000,
      line_total: 1_000,
      tax_rate: BigDecimal('0.1'),
      needs_review: false,
      review_reasons: []
    )
    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => item_attributes(item, line_total: 900).merge(discount_rate: '10')
        }
      }
    }
    discounted = receipt.reload.attributes.slice('subtotal_amount', 'tax_amount', 'total_amount')

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => item_attributes(item.reload, line_total: 900).merge(discount_rate: '')
        }
      }
    }
    restored = receipt.reload.attributes.slice('subtotal_amount', 'tax_amount', 'total_amount')

    aggregate_failures do
      expect(discounted).to eq('subtotal_amount' => 900, 'tax_amount' => 90, 'total_amount' => 990)
      expect(response).to have_http_status(:redirect)
      expect(restored).to eq('subtotal_amount' => 1_000, 'tax_amount' => 100, 'total_amount' => 1_100)
      expect(item.reload.attributes).to include(
        'price' => 1_000,
        'discount_rate' => nil,
        'original_line_total' => 1_000,
        'line_total' => 1_000
      )
    end
  end

  it 'countableから重量単位へ変更してもcurrent pre-discount sourceへ割引を一度だけ適用する' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 100,
      tax_amount: 0,
      total_amount: 100,
      amount_calculation_profile: {
        'schema_version' => 1,
        'context' => 'analysis',
        'profile' => {
          'tax_rounding_mode' => 'floor',
          'discount_rounding_mode' => 'round',
          'receipt_tax_basis' => 'total_includes_tax',
          'item_amount_basis' => 'line_total_as_recorded'
        }
      }
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '量り売り商品',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 100,
      line_total: 100,
      tax_rate: 0,
      needs_review: false,
      review_reasons: []
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => item_attributes(item, quantity: 2, line_total: 180).merge(
            quantity_unit_code: 'kilogram',
            discount_rate: '10',
            original_line_total: '200'
          )
        }
      }
    }
    receipt.reload

    aggregate_failures do
      expect(response).to have_http_status(:redirect)
      expect(receipt.attributes).to include(
        'subtotal_amount' => 180,
        'tax_amount' => 0,
        'total_amount' => 180
      )
      expect(item.reload.attributes).to include(
        'quantity_unit_code' => 'kilogram',
        'original_line_total' => 200,
        'discount_rate' => BigDecimal('0.1'),
        'line_total' => 180
      )
    end
  end

  it 'price空欄のcountable itemは再計算と保存でも明示line_totalを失わない' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 500,
      tax_amount: 0,
      total_amount: 500,
      amount_calculation_profile: {
        'schema_version' => 1,
        'context' => 'analysis',
        'profile' => {
          'tax_rounding_mode' => 'floor',
          'discount_rounding_mode' => 'round',
          'receipt_tax_basis' => 'total_includes_tax',
          'item_amount_basis' => 'line_total_as_recorded'
        }
      }
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '総額のみ商品',
      price: nil,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 500,
      line_total: 500,
      tax_rate: 0,
      needs_review: false,
      review_reasons: []
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => item_attributes(item, quantity: 2, line_total: 500)
        }
      }
    }
    receipt.reload

    aggregate_failures do
      expect(response).to have_http_status(:redirect)
      expect(receipt.attributes).to include(
        'subtotal_amount' => 500,
        'tax_amount' => 0,
        'total_amount' => 500
      )
      expect(item.reload.attributes).to include(
        'price' => nil,
        'quantity' => BigDecimal('2'),
        'original_line_total' => 500,
        'line_total' => 500
      )
    end
  end

  it '一時的なprice入力を空欄へ戻した後もcurrent sourceへ割引を一度だけ適用する' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 500,
      tax_amount: 0,
      total_amount: 500,
      amount_calculation_profile: {
        'schema_version' => 1,
        'context' => 'analysis',
        'profile' => {
          'tax_rounding_mode' => 'floor',
          'discount_rounding_mode' => 'round',
          'receipt_tax_basis' => 'total_includes_tax',
          'item_amount_basis' => 'line_total_as_recorded'
        }
      }
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '総額のみ割引商品',
      price: nil,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 500,
      line_total: 500,
      tax_rate: 0,
      needs_review: false,
      review_reasons: []
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => item_attributes(item, line_total: 450).merge(
            price: '',
            discount_rate: '10',
            original_line_total: '500'
          )
        }
      }
    }
    receipt.reload

    aggregate_failures do
      expect(response).to have_http_status(:redirect)
      expect(receipt.attributes).to include(
        'subtotal_amount' => 450,
        'tax_amount' => 0,
        'total_amount' => 450
      )
      expect(item.reload.attributes).to include(
        'price' => nil,
        'original_line_total' => 500,
        'discount_rate' => BigDecimal('0.1'),
        'line_total' => 450
      )
    end
  end

  it '金額未入力のplaceholder itemだけなら保存済みreceipt金額とblank sourceを維持する' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      memo: '変更前',
      subtotal_amount: 91,
      tax_amount: 9,
      total_amount: 100,
      amount_calculation_profile: {
        'schema_version' => 1,
        'context' => 'analysis',
        'profile' => {
          'tax_rounding_mode' => 'floor',
          'discount_rounding_mode' => 'round',
          'receipt_tax_basis' => 'tax_added_to_subtotal',
          'item_amount_basis' => 'line_total_as_net'
        }
      }
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '金額未入力',
      price: nil,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: nil,
      line_total: nil,
      tax_rate: nil,
      needs_review: true,
      review_reasons: [ 'item_amount_missing' ]
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        memo: '変更後',
        receipt_items_attributes: {
          '0' => {
            id: item.id,
            confirmed_name: item.confirmed_name,
            price: '',
            quantity: '2',
            quantity_unit_code: 'each',
            tax_rate: '',
            discount_rate: '',
            original_line_total: '',
            line_total: '',
            _destroy: '0'
          }
        }
      }
    }
    receipt.reload

    aggregate_failures do
      expect(response).to have_http_status(:redirect)
      expect(receipt.attributes).to include(
        'memo' => '変更後',
        'subtotal_amount' => 91,
        'tax_amount' => 9,
        'total_amount' => 100
      )
      expect(item.reload.attributes).to include(
        'price' => nil,
        'quantity' => BigDecimal('2'),
        'original_line_total' => nil,
        'line_total' => nil
      )
    end
  end

  it '保存済みtax detailの数値証拠が不整合ならJSと再計算の双方で除外する' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 110,
      tax_amount: 10,
      total_amount: 120,
      amount_calculation_profile: external_net_profile
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '課税商品',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 100,
      line_total: 100,
      tax_rate: BigDecimal('0.1'),
      needs_review: false,
      review_reasons: []
    )
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'delivery_fee',
      label: '送料',
      amount: 10,
      sign: 'surcharge',
      tax_rate: nil,
      source: 'manual',
      needs_review: false
    )
    receipt.receipt_tax_details.create!(rate: BigDecimal('0.08'), net_amount: 100, amount: 99)

    get edit_receipt_path(receipt)
    form = Nokogiri::HTML(response.body).at_css('[data-controller~="receipt-form"]')

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: { '0' => item_attributes(item) },
        receipt_adjustments_attributes: {
          '0' => {
            id: adjustment.id,
            kind: adjustment.kind,
            label: adjustment.label,
            amount: adjustment.amount,
            sign: adjustment.sign,
            tax_rate: '',
            _destroy: '0'
          }
        }
      }
    }
    receipt.reload

    aggregate_failures do
      expect(form['data-receipt-form-adjustment-tax-detail-evidence-stale-value']).to eq('true')
      expect(response).to have_http_status(:redirect)
      expect(receipt.attributes).to include(
        'subtotal_amount' => 110,
        'tax_amount' => 11,
        'total_amount' => 121
      )
    end
  end

  it '数値入力不正の早期422でもsubmitted purchase変更をJSへ渡し再送結果と一致させる' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 110,
      tax_amount: 8,
      total_amount: 118,
      amount_calculation_profile: {
        'schema_version' => 1,
        'context' => 'analysis',
        'profile' => {
          'tax_rounding_mode' => 'floor',
          'discount_rounding_mode' => 'round',
          'receipt_tax_basis' => 'tax_added_to_subtotal',
          'item_amount_basis' => 'line_total_as_net'
        }
      }
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '課税商品',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 100,
      line_total: 100,
      tax_rate: BigDecimal('0.08'),
      needs_review: false,
      review_reasons: []
    )
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'delivery_fee',
      label: '送料',
      amount: 10,
      sign: 'surcharge',
      tax_rate: nil,
      source: 'manual',
      needs_review: false
    )
    payment = receipt.receipt_payments.create!(method: 'cash', amount: 118)
    receipt.receipt_tax_details.create!(rate: BigDecimal('0.08'), net_amount: 110, amount: 8)
    changed_items = {
      '0' => item_attributes(item).merge(tax_rate: '10', original_line_total: '100', line_total: '100')
    }
    changed_adjustments = {
      '0' => {
        id: adjustment.id,
        kind: adjustment.kind,
        label: adjustment.label,
        amount: adjustment.amount,
        sign: adjustment.sign,
        tax_rate: '',
        _destroy: '0'
      }
    }

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: changed_items,
        receipt_adjustments_attributes: changed_adjustments,
        receipt_payments_attributes: {
          '0' => { id: payment.id, method: payment.method, amount: 'invalid', _destroy: '0' }
        }
      }
    }

    document = Nokogiri::HTML(response.body)
    form = document.at_css('[data-controller~="receipt-form"]')
    submitted_tax_rate = document.at_css('[data-receipt-form-target="taxRateInput"]')

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(form['data-receipt-form-purchase-inputs-changed-value']).to eq('true')
      expect(form['data-receipt-form-adjustment-tax-detail-rates-value']).to eq('["8"]')
      expect(submitted_tax_rate['value']).to eq('10')
      expect(receipt.reload.attributes).to include(
        'subtotal_amount' => 110,
        'tax_amount' => 8,
        'total_amount' => 118
      )
    end

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: changed_items,
        receipt_adjustments_attributes: changed_adjustments,
        receipt_payments_attributes: {
          '0' => { id: payment.id, method: payment.method, amount: '121', _destroy: '0' }
        }
      }
    }
    receipt.reload

    aggregate_failures do
      expect(response).to have_http_status(:redirect)
      expect(receipt.attributes).to include(
        'subtotal_amount' => 110,
        'tax_amount' => 11,
        'total_amount' => 121
      )
    end

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: { '0' => item_attributes(item.reload) },
        receipt_adjustments_attributes: {
          '0' => {
            id: adjustment.reload.id,
            kind: adjustment.kind,
            label: adjustment.label,
            amount: adjustment.amount,
            sign: adjustment.sign,
            tax_rate: '',
            _destroy: '0'
          }
        },
        receipt_payments_attributes: {
          '0' => { id: payment.reload.id, method: payment.method, amount: 'invalid', _destroy: '0' }
        }
      }
    }
    unchanged_form = Nokogiri::HTML(response.body).at_css('[data-controller~="receipt-form"]')

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(unchanged_form['data-receipt-form-purchase-inputs-changed-value']).to eq('false')
      expect(receipt.reload.total_amount).to eq(121)
    end
  end

  it '不正なoriginal_line_totalを422でsource表示しDBへ保存しない' do
    receipt, items = create_external_net_receipt
    initial_purchase_fingerprint = '{"items":[],"adjustments":[]}'
    get edit_receipt_path(
      receipt,
      receipt_form_initial_purchase_input_fingerprint: 'query-injected-fingerprint'
    )
    clean_get_fingerprint = Nokogiri::HTML(response.body).at_css(
      "input[name='receipt_form_initial_purchase_input_fingerprint']"
    )
    submitted_items = items.each_with_index.to_h do |item, index|
      attributes = item_attributes(item)
      attributes[:original_line_total] = '12abc' if index.zero?
      [ index.to_s, attributes ]
    end

    patch receipt_path(receipt), params: {
      receipt_form_initial_purchase_input_fingerprint: initial_purchase_fingerprint,
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: submitted_items
      }
    }

    document = Nokogiri::HTML(response.body)
    form = document.at_css('[data-controller~="receipt-form"]')
    submitted_source = document.at_css(
      "input[name='receipt[receipt_items_attributes][0][original_line_total]']"
    )
    submitted_fingerprint = document.at_css(
      "input[name='receipt_form_initial_purchase_input_fingerprint']"
    )

    aggregate_failures do
      expect(clean_get_fingerprint['value']).to be_blank
      expect(response).to have_http_status(:unprocessable_content)
      expect(form['data-receipt-form-purchase-inputs-changed-value']).to eq('true')
      expect(submitted_source['value']).to eq('12abc')
      expect(submitted_fingerprint['value']).to eq(initial_purchase_fingerprint)
      expect(receipt.reload.attributes).to include(
        'subtotal_amount' => 742,
        'tax_amount' => 59,
        'total_amount' => 801
      )
      expect(items.first.reload.attributes).to include(
        'price' => 128,
        'original_line_total' => 128,
        'line_total' => 128
      )
    end
  end

  it '金額上限の早期422でもsubmitted purchase変更をJSへ渡す' do
    receipt, items = create_external_net_receipt
    create(
      :system_setting,
      key: 'limits.receipt_payment_amount_max',
      value: SystemSettings.stored_value(500)
    )
    submitted_items = items.each_with_index.to_h do |item, index|
      attributes = item_attributes(item)
      attributes[:tax_rate] = '10' if index.zero?
      [ index.to_s, attributes ]
    end

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: submitted_items
      }
    }

    document = Nokogiri::HTML(response.body)
    form = document.at_css('[data-controller~="receipt-form"]')

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(form['data-receipt-form-purchase-inputs-changed-value']).to eq('true')
      expect(receipt.reload.attributes).to include(
        'subtotal_amount' => 742,
        'tax_amount' => 59,
        'total_amount' => 801
      )
      expect(items.first.reload.tax_rate).to eq(BigDecimal('0.08'))
    end
  end

  it 'adjustment labelのnilとblankの差だけでは保存済みtax rate evidenceを破棄しない' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 101,
      tax_amount: 9,
      total_amount: 110,
      amount_calculation_profile: {
        'schema_version' => 1,
        'context' => 'analysis',
        'profile' => {
          'tax_rounding_mode' => 'floor',
          'discount_rounding_mode' => 'round',
          'receipt_tax_basis' => 'total_includes_tax',
          'item_amount_basis' => 'line_total_as_recorded'
        }
      }
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '課税商品',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 100,
      line_total: 100,
      tax_rate: BigDecimal('0.1'),
      needs_review: false,
      review_reasons: []
    )
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'delivery_fee',
      label: nil,
      amount: 10,
      sign: 'surcharge',
      tax_rate: nil,
      source: 'manual',
      needs_review: false
    )
    receipt.receipt_tax_details.create!(rate: BigDecimal('0.08'), net_amount: 101, amount: 9)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: { '0' => item_attributes(item) },
        receipt_adjustments_attributes: {
          '0' => {
            id: adjustment.id,
            kind: adjustment.kind,
            label: '',
            amount: adjustment.amount,
            sign: adjustment.sign,
            tax_rate: '',
            _destroy: '0'
          }
        }
      }
    }
    receipt.reload

    aggregate_failures do
      expect(response).to have_http_status(:redirect)
      expect(receipt.attributes).to include(
        'subtotal_amount' => 101,
        'tax_amount' => 9,
        'total_amount' => 110
      )
      expect(receipt.receipt_tax_details.sole.rate).to eq(BigDecimal('0.08'))
    end
  end

  it '購入入力変更後はstale tax detailを外し、blank購入調整へ現在の単一税率を継承する' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 14,
      tax_amount: 1,
      total_amount: 15,
      amount_calculation_profile: external_net_profile
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '単一税率商品',
      price: 7,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 7,
      line_total: 7,
      tax_rate: BigDecimal('0.08'),
      needs_review: false,
      review_reasons: []
    )
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'delivery_fee',
      label: '送料',
      amount: 7,
      sign: 'surcharge',
      tax_rate: nil,
      source: 'manual',
      needs_review: false
    )
    receipt.receipt_tax_details.create!(rate: BigDecimal('0.08'), net_amount: 14, amount: 1)
    receipt.receipt_payments.create!(method: 'cash', amount: 15)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => item_attributes(item).merge(tax_rate: '10')
        },
        receipt_adjustments_attributes: {
          '0' => {
            id: adjustment.id,
            kind: adjustment.kind,
            label: adjustment.label,
            amount: adjustment.amount,
            sign: adjustment.sign,
            tax_rate: '',
            _destroy: '0'
          }
        }
      }
    }
    receipt.reload

    aggregate_failures do
      expect(response).to have_http_status(:redirect)
      expect(receipt.attributes).to include(
        'subtotal_amount' => 14,
        'tax_amount' => 1,
        'total_amount' => 15
      )
      expect(adjustment.reload.tax_rate).to be_nil
      expect(receipt.receipt_tax_details.reload.map { |detail| [ detail.rate.to_s('F'), detail.net_amount, detail.amount ] }).to eq(
        [ [ '0.1', 14, 1 ] ]
      )
    end
  end

  it 'quantityを2へ保存してから1へ戻すと初期金額とnet sourceへ復帰する' do
    receipt, items = create_external_net_receipt

    submit_first_quantity(receipt, items, 2)
    doubled = saved_amount_snapshot(receipt)

    get edit_receipt_path(receipt)
    doubled_edit = rendered_edit_snapshot(Nokogiri::HTML(response.body), item_id: items.first.id)

    submit_first_quantity(receipt, items, 1)
    restored = saved_amount_snapshot(receipt)

    aggregate_failures do
      expect(doubled).to eq(expected_saved_snapshot(subtotal: 870, tax: 69, total: 939, quantity: 2, first_line_total: 256))
      expect(doubled_edit).to eq(
        status: 200,
        basis: 'external',
        first_price: 128,
        first_quantity: '2',
        first_line_total: 256
      )
      expect(restored).to eq(expected_saved_snapshot(subtotal: 742, tax: 59, total: 801, quantity: 1, first_line_total: 128))
    end
  end

  it 'quantityの保存往復を2回繰り返しても金額とnet sourceが変化しない' do
    receipt, items = create_external_net_receipt
    snapshots = []

    2.times do
      submit_first_quantity(receipt, items, 2)
      snapshots << saved_amount_snapshot(receipt)

      submit_first_quantity(receipt, items, 1)
      snapshots << saved_amount_snapshot(receipt)
    end

    expect(snapshots).to eq(
      [
        expected_saved_snapshot(subtotal: 870, tax: 69, total: 939, quantity: 2, first_line_total: 256),
        expected_saved_snapshot(subtotal: 742, tax: 59, total: 801, quantity: 1, first_line_total: 128)
      ] * 2
    )
  end

  it '422再表示と再送でsubmitted sourceをcomputed grossへ置き換えずDBも変更しない' do
    receipt, items = create_external_net_receipt
    original_receipt_values = receipt.attributes.slice('subtotal_amount', 'tax_amount', 'total_amount', 'lock_version')
    original_item_values = items.map do |item|
      item.attributes.slice('price', 'quantity', 'original_line_total', 'line_total')
    end
    first_source_attributes = nil
    first_source_snapshot = nil
    persistence_attributes = nil

    allow(ReceiptAmountService).to receive(:call).and_return(forced_external_result)
    allow(Receipts::Editing).to receive(:build_input).and_wrap_original do |original, **arguments|
      first_source_attributes ||= arguments.fetch(:permitted)
      first_source_snapshot ||= first_source_attributes.deep_dup
      original.call(**arguments)
    end
    allow(Receipts::Editing).to receive(:apply_amount_result!).and_wrap_original do |original, **arguments|
      persistence_attributes ||= arguments.fetch(:attributes)
      original.call(**arguments)
    end
    allow(Receipts::Editing).to receive(:check_consistency).and_return(
      Receipts::Editing::ConsistencyGuard::Result.new(
        fatal_errors: [ :child_purchase_total_mismatch ],
        review_reasons: []
      )
    )

    submit_first_quantity(receipt, items, 1)
    first_status = response.status
    first_document = Nokogiri::HTML(response.body)
    first_rendered_items = rendered_item_attributes(first_document)
    first_receipt_values = receipt.reload.attributes.slice(*original_receipt_values.keys)
    first_item_values = items.map { |item| item.reload.attributes.slice(*original_item_values.first.keys) }

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.reload.lock_version,
        receipt_items_attributes: first_rendered_items
      }
    }
    second_status = response.status
    second_document = Nokogiri::HTML(response.body)
    second_rendered_items = rendered_item_attributes(second_document)
    second_receipt_values = receipt.reload.attributes.slice(*original_receipt_values.keys)
    second_item_values = items.map { |item| item.reload.attributes.slice(*original_item_values.first.keys) }

    aggregate_failures do
      expect(first_status).to eq(422)
      expect(second_status).to eq(422)
      expect(persistence_attributes).not_to equal(first_source_attributes)
      expect(first_source_attributes).to eq(first_source_snapshot)
      expect(rendered_values_in_item_order(first_rendered_items, items, :price).map(&:to_i)).to eq([ 128, 198, 115, 298, 3 ])
      expect(rendered_values_in_item_order(first_rendered_items, items, :quantity)).to eq([ '1', '1', '1', '1', '1' ])
      expect(rendered_values_in_item_order(first_rendered_items, items, :line_total).map(&:to_i)).to eq([ 128, 198, 115, 298, 3 ])
      expect(rendered_values_in_item_order(second_rendered_items, items, :price).map(&:to_i)).to eq([ 128, 198, 115, 298, 3 ])
      expect(rendered_values_in_item_order(second_rendered_items, items, :line_total).map(&:to_i)).to eq([ 128, 198, 115, 298, 3 ])
      expect(first_receipt_values).to eq(original_receipt_values)
      expect(second_receipt_values).to eq(original_receipt_values)
      expect(first_item_values).to eq(original_item_values)
      expect(second_item_values).to eq(original_item_values)
    end
  end

  it 'model validation失敗でもcomputed grossを再表示sourceへ昇格させない' do
    receipt, items = create_external_net_receipt
    original_receipt_values = receipt.attributes.slice('store_name', 'subtotal_amount', 'tax_amount', 'total_amount')
    original_item_values = items.map do |item|
      item.attributes.slice('price', 'quantity', 'original_line_total', 'line_total')
    end
    attributes = items.each_with_index.to_h do |item, index|
      [ index.to_s, item_attributes(item) ]
    end

    allow(ReceiptAmountService).to receive(:call).and_return(forced_external_result)
    allow(Receipts::Editing).to receive(:check_consistency).and_return(
      Receipts::Editing::ConsistencyGuard::Result.new(fatal_errors: [], review_reasons: [])
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        store_name: '',
        receipt_items_attributes: attributes
      }
    }

    rendered_items = rendered_item_attributes(Nokogiri::HTML(response.body))

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(rendered_values_in_item_order(rendered_items, items, :price).map(&:to_i)).to eq([ 128, 198, 115, 298, 3 ])
      expect(rendered_values_in_item_order(rendered_items, items, :line_total).map(&:to_i)).to eq([ 128, 198, 115, 298, 3 ])
      expect(receipt.reload.attributes.slice(*original_receipt_values.keys)).to eq(original_receipt_values)
      expect(items.map { |item| item.reload.attributes.slice(*original_item_values.first.keys) }).to eq(original_item_values)
    end
  end

  it '新規nested itemを含むvalidation失敗でも行を重複させずsourceとchild errorを維持する' do
    receipt, items = create_external_net_receipt
    invalid_name = '長' * 501
    attributes = items.each_with_index.to_h do |item, index|
      [ index.to_s, item_attributes(item) ]
    end
    attributes['5'] = {
      confirmed_name: invalid_name,
      price: '50',
      quantity: '1',
      quantity_unit_code: 'each',
      tax_rate: '10',
      line_total: '50',
      _destroy: '0'
    }

    allow(ReceiptAmountService).to receive(:call).and_return(forced_external_result)
    allow(Receipts::Editing).to receive(:check_consistency).and_return(
      Receipts::Editing::ConsistencyGuard::Result.new(fatal_errors: [], review_reasons: [])
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        store_name: '',
        receipt_items_attributes: attributes
      }
    }

    document = Nokogiri::HTML(response.body)
    rows = document.css(
      '[data-receipt-form-target="itemsContainer"] > [data-controller~="swipe-action"] [data-receipt-form-target="itemRow"]'
    )
    invalid_name_input = rows.filter_map { |row| row.at_css('input[name$="[confirmed_name]"]') }
      .find { |input| input['value'] == invalid_name }

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(rows.size).to eq(6)
      expect(invalid_name_input).to be_present
      expect(invalid_name_input['class']).to include('input-field-error')
      expect(receipt.reload.receipt_items.count).to eq(5)
    end
  end
end
