require 'rails_helper'

RSpec.describe 'Receipt measurement pricing persistence contract', type: :request do
  SOURCE_FIELDS = %w[
    pricing_source_kind
    reference_price_amount
    reference_quantity
    reference_quantity_unit_code
    quantity_unit_raw
    reference_quantity_unit_raw
    reference_price_tax_inclusion
  ].freeze

  let(:user) { create(:user) }

  before do
    sign_in user
  end

  def reference_source_attributes(overrides = {})
    {
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: '120',
      reference_quantity: '500',
      reference_quantity_unit_code: 'milliliter',
      quantity_unit_raw: '',
      reference_quantity_unit_raw: '',
      reference_price_tax_inclusion: 'gross'
    }.merge(overrides)
  end

  def item_attributes(item, overrides = {})
    {
      id: item.id,
      confirmed_name: item.confirmed_name,
      category: item.category,
      price: item.price,
      quantity: item.quantity.to_s('F'),
      quantity_unit_code: item.quantity_unit_code,
      product_code: item.product_code,
      tax_rate: item.tax_rate&.*(100),
      discount_rate: item.discount_rate&.*(100),
      original_line_total: item.original_line_total,
      line_total: item.line_total,
      position_index: item.position_index,
      pricing_source_kind: item.pricing_source_kind,
      reference_price_amount: item.reference_price_amount&.to_s('F'),
      reference_quantity: item.reference_quantity&.to_s('F'),
      reference_quantity_unit_code: item.reference_quantity_unit_code,
      quantity_unit_raw: item.quantity_unit_raw,
      reference_quantity_unit_raw: item.reference_quantity_unit_raw,
      reference_price_tax_inclusion: item.reference_price_tax_inclusion,
      _destroy: '0'
    }.merge(overrides)
  end

  def create_reference_receipt(
    quantity: BigDecimal('750'),
    quantity_unit_code: 'milliliter',
    reference_price_amount: BigDecimal('120'),
    reference_quantity: BigDecimal('500'),
    reference_quantity_unit_code: 'milliliter',
    reference_price_tax_inclusion: 'gross',
    tax_rate: BigDecimal('0'),
    line_total: 180,
    subtotal_amount: line_total,
    tax_amount: 0,
    total_amount: line_total,
    amount_calculation_profile: {}
  )
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      store_name: '基準価格保存店',
      purchased_at: 1.day.ago,
      payment_method: 'cash',
      subtotal_amount: subtotal_amount,
      tax_amount: tax_amount,
      total_amount: total_amount,
      review_reasons: [],
      amount_calculation_profile: amount_calculation_profile
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '基準価格商品',
      price: nil,
      quantity: quantity,
      quantity_unit_code: quantity_unit_code,
      tax_rate: tax_rate,
      original_line_total: line_total,
      line_total: line_total,
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: reference_price_amount,
      reference_quantity: reference_quantity,
      reference_quantity_unit_code: reference_quantity_unit_code,
      quantity_unit_raw: nil,
      reference_quantity_unit_raw: nil,
      reference_price_tax_inclusion: reference_price_tax_inclusion,
      needs_review: false,
      review_reasons: []
    )

    [ receipt, item ]
  end

  def create_original_unrecorded_discounted_explicit_receipt
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      store_name: 'authority未記録明示金額店',
      subtotal_amount: 164,
      tax_amount: 16,
      total_amount: 180,
      tax_rate: BigDecimal('0.1'),
      review_reasons: [],
      amount_calculation_profile: {
        'schema_version' => 1,
        'context' => 'analysis',
        'profile' => {
          'tax_rounding_mode' => 'floor',
          'discount_rounding_mode' => 'round',
          'receipt_tax_basis' => 'total_includes_tax',
          'item_amount_basis' => 'line_total_as_recorded',
          'tax_detail_amount_basis' => 'gross'
        }
      }
    )
    item = receipt.receipt_items.create!(
      confirmed_name: 'authority未記録割引商品',
      pricing_source_kind: 'explicit_line_total',
      quantity: BigDecimal('1'),
      quantity_unit_code: 'each',
      original_line_total: nil,
      discount_rate: BigDecimal('0.1'),
      discount_amount: 18,
      line_total: 180,
      tax_rate: BigDecimal('0.1'),
      needs_review: false,
      review_reasons: []
    )
    receipt.receipt_tax_details.create!(
      description: '10%対象',
      rate: BigDecimal('0.1'),
      net_amount: 164,
      amount: 16
    )

    [ receipt, item ]
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
      }
    }
  end

  def persisted_snapshot(receipt, item)
    receipt.reload
    item.reload

    {
      receipt: receipt.attributes.slice('subtotal_amount', 'tax_amount', 'total_amount', 'lock_version'),
      item: item.attributes.slice(
        'price',
        'quantity',
        'quantity_unit_code',
        'discount_amount',
        'discount_rate',
        'original_line_total',
        'line_total',
        *SOURCE_FIELDS
      )
    }
  end

  def persisted_graph_snapshot(receipt)
    receipt.reload

    {
      receipt: receipt.attributes.deep_dup,
      receipt_items: receipt.receipt_items.reload.sort_by(&:id).map { |record| record.attributes.deep_dup },
      receipt_tax_details: receipt.receipt_tax_details.reload.sort_by(&:id).map { |record| record.attributes.deep_dup },
      receipt_adjustments: receipt.receipt_adjustments.reload.sort_by(&:id).map { |record| record.attributes.deep_dup },
      receipt_payments: receipt.receipt_payments.reload.sort_by(&:id).map { |record| record.attributes.deep_dup }
    }
  end

  def patch_item(receipt, item, overrides = {}, lock_version: receipt.reload.lock_version)
    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: lock_version,
        receipt_items_attributes: {
          '0' => item_attributes(item.reload, overrides)
        }
      }
    }
  end

  def presented_source(arguments, item_id)
    submitted_rows = arguments.fetch(:submitted_params, {}).to_h
      .fetch('receipt_items_attributes', {})
    submitted = submitted_rows.values.find { |row| row['id'].to_s == item_id.to_s } || {}
    presented_item = arguments.fetch(:receipt).receipt_items.find { |candidate| candidate.id == item_id }

    SOURCE_FIELDS.to_h do |field|
      value = submitted.key?(field) ? submitted[field] : presented_item&.public_send(field)
      [ field, value ]
    end
  end

  it 'manual gross formulaのexact sourceを保存し、tampered hidden totalをderivedへ置き換える' do
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '手動基準価格店',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '750ml商品',
              price: '',
              quantity: '750',
              quantity_unit_code: 'milliliter',
              tax_rate: '0',
              original_line_total: '998',
              line_total: '999',
              **reference_source_attributes
            }
          }
        }
      }
    end.to change(Receipt, :count).by(1)

    receipt = user.receipts.find_by!(store_name: '手動基準価格店')
    item = receipt.receipt_items.sole

    aggregate_failures do
      expect(response).to redirect_to(receipts_path)
      expect(receipt).to have_attributes(subtotal_amount: 180, tax_amount: 0, total_amount: 180)
      expect(item).to have_attributes(
        price: nil,
        quantity: BigDecimal('750'),
        quantity_unit_code: 'milliliter',
        pricing_source_kind: 'reference_quantity_price',
        reference_price_amount: BigDecimal('120'),
        reference_quantity: BigDecimal('500'),
        reference_quantity_unit_code: 'milliliter',
        quantity_unit_raw: nil,
        reference_quantity_unit_raw: nil,
        reference_price_tax_inclusion: 'gross',
        original_line_total: 180,
        line_total: 180
      )
      expect(item.reference_price_amount).not_to eq(item.line_total)
    end
  end

  it 'reference authorityに属さないpriceとhidden totalsが上限超過でも無視して保存する' do
    hidden_price = ReceiptAmountService.receipt_item_price_max + 1
    hidden_total = ReceiptAmountService.receipt_item_line_total_max + 1

    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '非authority無視店',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '750ml商品',
              price: hidden_price,
              quantity: '750',
              quantity_unit_code: 'milliliter',
              tax_rate: '0',
              original_line_total: hidden_total,
              line_total: hidden_total,
              **reference_source_attributes
            }
          }
        }
      }
    end.to change(Receipt, :count).by(1)

    item = user.receipts.find_by!(store_name: '非authority無視店').receipt_items.sole
    aggregate_failures do
      expect(response).to redirect_to(receipts_path)
      expect(item).to have_attributes(price: nil, original_line_total: 180, line_total: 180)
    end
  end

  it 'count formulaのhidden totalsが上限超過でもpriceとquantityから再計算する' do
    hidden_total = ReceiptAmountService.receipt_item_line_total_max + 1

    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '個数formula店',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '個数商品',
              pricing_source_kind: 'count_unit_price',
              price: '100',
              quantity: '2',
              quantity_unit_code: 'each',
              original_line_total: hidden_total,
              line_total: hidden_total,
              tax_rate: '0'
            }
          }
        }
      }
    end.to change(Receipt, :count).by(1)

    item = user.receipts.find_by!(store_name: '個数formula店').receipt_items.sole
    aggregate_failures do
      expect(response).to redirect_to(receipts_path)
      expect(item).to have_attributes(price: 100, original_line_total: 200, line_total: 200)
    end
  end

  it 'formulaの実計算結果がline total上限を超える場合は422で保存しない' do
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '計算上限超過店',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '上限超過商品',
              quantity: '9999.999',
              quantity_unit_code: 'gram',
              **reference_source_attributes(
                reference_price_amount: '999999999999',
                reference_quantity: '0.001',
                reference_quantity_unit_code: 'gram'
              )
            }
          }
        }
      }
    end.not_to change(Receipt, :count)

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('receipts.form.errors.amount_limit_exceeded',
        resource: 'receipt_items',
        field: 'line_total',
        limit: ReceiptAmountService.receipt_item_line_total_max,
        actual_value: 9_999_998_999_990_000_001))
    end
  end

  it '0円のreference/count formula sourceをblank行として除外せず保存する' do
    cases = [
      {
        store_name: '0円reference formula店',
        item: {
          confirmed_name: '0円reference商品',
          price: '',
          quantity: '750',
          quantity_unit_code: 'milliliter',
          original_line_total: '',
          line_total: '',
          tax_rate: '0',
          **reference_source_attributes(reference_price_amount: '0')
        },
        expected: {
          pricing_source_kind: 'reference_quantity_price',
          price: nil,
          reference_price_amount: BigDecimal('0'),
          line_total: 0,
          original_line_total: 0
        }
      },
      {
        store_name: '0円count formula店',
        item: {
          confirmed_name: '0円count商品',
          pricing_source_kind: 'count_unit_price',
          price: '0',
          quantity: '2',
          quantity_unit_code: 'each',
          original_line_total: '',
          line_total: '',
          tax_rate: '0'
        },
        expected: {
          pricing_source_kind: 'count_unit_price',
          price: 0,
          reference_price_amount: nil,
          line_total: 0,
          original_line_total: 0
        }
      }
    ]

    cases.each do |test_case|
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: test_case.fetch(:store_name),
            payment_method: 'cash',
            receipt_items_attributes: { '0' => test_case.fetch(:item) }
          }
        }
      end.to change(Receipt, :count).by(1)

      receipt = user.receipts.find_by!(store_name: test_case.fetch(:store_name))
      aggregate_failures test_case.fetch(:store_name) do
        expect(response).to redirect_to(receipts_path)
        expect(receipt).to have_attributes(subtotal_amount: 0, tax_amount: 0, total_amount: 0)
        expect(receipt.receipt_items.sole).to have_attributes(test_case.fetch(:expected))
      end
    end
  end

  it '全measurement pricing source fieldがblankの新規行を0円itemへ昇格させない' do
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: 'blank source除外店',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '',
              category: '',
              price: '',
              quantity: '1',
              quantity_unit_code: 'each',
              original_line_total: '',
              line_total: '0',
              tax_rate: '',
              **SOURCE_FIELDS.to_h { |field| [ field, '' ] }
            }
          }
        }
      }
    end.not_to change(Receipt, :count)

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('receipts.form.errors.items_required'))
      expect(ReceiptItem.where(confirmed_name: '').count).to eq(0)
    end
  end

  it 'pricing modeと自動入力metadataだけの新規行を永続化しない' do
    %w[count_unit_price reference_quantity_price explicit_line_total].each do |pricing_source_kind|
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: "modeのみ除外店 #{pricing_source_kind}",
            payment_method: 'cash',
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '',
                category: '',
                pricing_source_kind: pricing_source_kind,
                quantity: '1',
                quantity_unit_code: 'each',
                reference_price_amount: '',
                reference_quantity: '',
                reference_quantity_unit_code: '',
                reference_price_tax_inclusion: pricing_source_kind == 'reference_quantity_price' ? 'gross' : '',
                price: '',
                original_line_total: '',
                line_total: '',
                tax_rate: ''
              }
            }
          }
        }
      end.not_to change(Receipt, :count)

      aggregate_failures pricing_source_kind do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('receipts.form.errors.items_required'))
      end
    end
  end

  it '商品名のある新規explicit rowのblank authorityを422にして保存しない' do
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: 'authority未入力店',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: 'authority未入力商品',
              pricing_source_kind: 'explicit_line_total',
              quantity: '1',
              quantity_unit_code: 'each',
              original_line_total: '',
              line_total: '999'
            }
          }
        }
      }
    end.not_to change(Receipt, :count)

    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'explicitな0円sourceをmodeだけの空行と区別して保存する' do
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '0円explicit店',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '',
              pricing_source_kind: 'explicit_line_total',
              quantity: '1',
              quantity_unit_code: 'each',
              original_line_total: '0',
              tax_rate: '0'
            }
          }
        }
      }
    end.to change(Receipt, :count).by(1)

    receipt = user.receipts.find_by!(store_name: '0円explicit店')
    aggregate_failures do
      expect(response).to redirect_to(receipts_path)
      expect(receipt).to have_attributes(subtotal_amount: 0, tax_amount: 0, total_amount: 0)
      expect(receipt.receipt_items.sole).to have_attributes(
        pricing_source_kind: 'explicit_line_total',
        original_line_total: 0,
        line_total: 0
      )
    end
  end

  it 'explicitのhidden line total改ざんを無視し、可視original line totalから再計算する' do
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: 'explicit authority店',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '明示金額商品',
              pricing_source_kind: 'explicit_line_total',
              quantity: '1',
              quantity_unit_code: 'each',
              original_line_total: '240',
              line_total: ReceiptAmountService.receipt_item_line_total_max + 1,
              tax_rate: '0'
            }
          }
        }
      }
    end.to change(Receipt, :count).by(1)

    receipt = user.receipts.find_by!(store_name: 'explicit authority店')
    aggregate_failures do
      expect(response).to redirect_to(receipts_path)
      expect(receipt).to have_attributes(subtotal_amount: 240, tax_amount: 0, total_amount: 240)
      expect(receipt.receipt_items.sole).to have_attributes(
        pricing_source_kind: 'explicit_line_total',
        original_line_total: 240,
        line_total: 240
      )
    end
  end

  it 'edit_saveのnet formulaでreference quantity変更をsourceとderivedへ一度だけ反映する' do
    receipt, item = create_reference_receipt(
      quantity: BigDecimal('1'),
      quantity_unit_code: 'liter',
      reference_price_amount: BigDecimal('110'),
      reference_quantity: BigDecimal('1'),
      reference_quantity_unit_code: 'liter',
      reference_price_tax_inclusion: 'net',
      tax_rate: BigDecimal('0.1'),
      line_total: 110,
      subtotal_amount: 110,
      tax_amount: 11,
      total_amount: 121,
      amount_calculation_profile: external_net_profile
    )
    receipt.receipt_tax_details.create!(rate: BigDecimal('0.1'), net_amount: 110, amount: 11)

    patch_item(
      receipt,
      item,
      {
        reference_quantity: '0.5',
        line_total: '999',
        original_line_total: '998'
      }
    )

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 220, tax_amount: 22, total_amount: 242)
      expect(item.reload).to have_attributes(
        reference_price_amount: BigDecimal('110'),
        reference_quantity: BigDecimal('0.5'),
        reference_quantity_unit_code: 'liter',
        reference_price_tax_inclusion: 'net',
        original_line_total: 220,
        line_total: 220
      )
    end
  end

  it 'edit_saveでtampered non-authority priceとhidden totalsを無視し、保存済みpriceを維持する' do
    receipt, item = create_reference_receipt
    item.update!(price: 999)
    hidden_price = ReceiptAmountService.receipt_item_price_max + 1
    hidden_total = ReceiptAmountService.receipt_item_line_total_max + 1

    patch_item(
      receipt,
      item,
      {
        price: hidden_price,
        quantity: '800',
        original_line_total: hidden_total,
        line_total: hidden_total
      }
    )

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(item.reload).to have_attributes(price: 999, original_line_total: 192, line_total: 192)
    end
  end

  it 'edit_saveでblank送信されたreferenceのnon-authority priceを保存済みdiagnostic値へ戻す' do
    receipt, item = create_reference_receipt
    item.update!(price: 999)

    patch_item(
      receipt,
      item,
      {
        price: '',
        quantity: '800',
        original_line_total: '',
        line_total: ''
      }
    )

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(item.reload).to have_attributes(price: 999, original_line_total: 192, line_total: 192)
    end
  end

  it 'save reload same-saveを繰り返してもsourceとderivedがdriftしない' do
    receipt, item = create_reference_receipt

    patch_item(receipt, item, { quantity: '800', line_total: '999' })
    first_save = persisted_snapshot(receipt, item)
    patch_item(receipt, item)
    second_save = persisted_snapshot(receipt, item)

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(first_save[:receipt].slice('subtotal_amount', 'tax_amount', 'total_amount')).to eq(
        'subtotal_amount' => 192,
        'tax_amount' => 0,
        'total_amount' => 192
      )
      expect(first_save[:item]).to include(
        'quantity' => BigDecimal('800'),
        'reference_price_amount' => BigDecimal('120'),
        'reference_quantity' => BigDecimal('500'),
        'original_line_total' => 192,
        'line_total' => 192
      )
      expect(second_save[:receipt].except('lock_version')).to eq(first_save[:receipt].except('lock_version'))
      expect(second_save[:item]).to eq(first_save[:item])
    end
  end

  it 'source kindをreferenceからexplicitへ切り替えて戻してもderivedをsourceへ昇格させない' do
    receipt, item = create_reference_receipt
    before = persisted_snapshot(receipt, item)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => { id: item.id, pricing_source_kind: 'explicit_line_total' }
        }
      }
    }

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(persisted_snapshot(receipt, item)).to eq(before)
    end

    patch_item(
      receipt,
      item,
      {
        pricing_source_kind: 'explicit_line_total',
        line_total: '999',
        original_line_total: '181'
      }
    )

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(item.reload).to have_attributes(
        pricing_source_kind: 'explicit_line_total',
        price: nil,
        reference_price_amount: nil,
        reference_quantity: nil,
        reference_quantity_unit_code: nil,
        reference_price_tax_inclusion: nil,
        original_line_total: 181,
        line_total: 181
      )
    end

    patch_item(
      receipt,
      item,
      {
        pricing_source_kind: 'reference_quantity_price',
        price: '999',
        quantity: '750',
        quantity_unit_code: 'milliliter',
        reference_price_amount: '120',
        reference_quantity: '500',
        reference_quantity_unit_code: 'milliliter',
        reference_price_tax_inclusion: 'gross',
        original_line_total: '999',
        line_total: '999'
      }
    )

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 180, tax_amount: 0, total_amount: 180)
      expect(item.reload).to have_attributes(
        pricing_source_kind: 'reference_quantity_price',
        price: nil,
        reference_price_amount: BigDecimal('120'),
        reference_quantity: BigDecimal('500'),
        reference_quantity_unit_code: 'milliliter',
        reference_price_tax_inclusion: 'gross',
        original_line_total: 180,
        line_total: 180
      )
    end
  end

  it 'count authorityへ切り替える際に非選択のreference draftを永続化しない' do
    receipt, item = create_reference_receipt

    patch_item(
      receipt,
      item,
      {
        pricing_source_kind: 'count_unit_price',
        price: '100',
        quantity: '2',
        quantity_unit_code: 'each',
        reference_price_amount: '999',
        reference_quantity: '9',
        reference_quantity_unit_code: 'each',
        reference_price_tax_inclusion: 'gross',
        original_line_total: '999',
        line_total: '999'
      }
    )

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 200, tax_amount: 0, total_amount: 200)
      expect(item.reload).to have_attributes(
        pricing_source_kind: 'count_unit_price',
        price: 100,
        quantity: BigDecimal('2'),
        quantity_unit_code: 'each',
        reference_price_amount: nil,
        reference_quantity: nil,
        reference_quantity_unit_code: nil,
        reference_price_tax_inclusion: nil,
        original_line_total: 200,
        line_total: 200
      )
    end
  end

  it '同一explicit authorityの通常保存で保存済みdiagnostic reference evidenceを消去しない' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 181,
      tax_amount: 0,
      total_amount: 181,
      review_reasons: []
    )
    item = receipt.receipt_items.create!(
      confirmed_name: 'diagnostic evidence付き明細',
      pricing_source_kind: 'explicit_line_total',
      quantity: BigDecimal('750'),
      quantity_unit_code: 'milliliter',
      reference_price_amount: BigDecimal('120'),
      reference_quantity: BigDecimal('500'),
      reference_quantity_unit_code: 'milliliter',
      reference_price_tax_inclusion: 'gross',
      original_line_total: 181,
      line_total: 181,
      tax_rate: BigDecimal('0')
    )

    patch_item(receipt, item, { confirmed_name: 'diagnostic evidenceを維持した明細' })

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(item.reload).to have_attributes(
        pricing_source_kind: 'explicit_line_total',
        reference_price_amount: BigDecimal('120'),
        reference_quantity: BigDecimal('500'),
        reference_quantity_unit_code: 'milliliter',
        reference_price_tax_inclusion: 'gross',
        original_line_total: 181,
        line_total: 181
      )
    end
  end

  it '割引済みexplicit authorityの同値保存で税投影をdriftさせず、authority変更だけを再計算する' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 164,
      tax_amount: 16,
      total_amount: 180,
      tax_rate: BigDecimal('0.1'),
      review_reasons: [],
      amount_calculation_profile: {
        'schema_version' => 1,
        'context' => 'analysis',
        'profile' => {
          'tax_rounding_mode' => 'floor',
          'discount_rounding_mode' => 'round',
          'receipt_tax_basis' => 'total_includes_tax',
          'item_amount_basis' => 'line_total_as_recorded',
          'tax_detail_amount_basis' => 'gross'
        }
      }
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '割引済み明示金額商品',
      pricing_source_kind: 'explicit_line_total',
      quantity: BigDecimal('1'),
      quantity_unit_code: 'each',
      original_line_total: 200,
      discount_rate: BigDecimal('0.1'),
      discount_amount: 20,
      line_total: 180,
      tax_rate: BigDecimal('0.1'),
      needs_review: false,
      review_reasons: []
    )
    receipt.receipt_tax_details.create!(
      description: '10%対象',
      rate: BigDecimal('0.1'),
      net_amount: 164,
      amount: 16
    )
    before_profile = receipt.amount_calculation_profile.fetch('profile').deep_dup
    before_tax_details = receipt.receipt_tax_details.map { |detail| detail.attributes.deep_dup }

    patch_item(receipt, item)

    aggregate_failures '同値保存' do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 164, tax_amount: 16, total_amount: 180)
      expect(receipt.amount_calculation_profile.fetch('profile')).to eq(before_profile)
      expect(receipt.receipt_tax_details.map { |detail| detail.attributes.deep_dup }).to eq(before_tax_details)
      expect(item.reload).to have_attributes(
        original_line_total: 200,
        discount_rate: BigDecimal('0.1'),
        discount_amount: 20,
        line_total: 180
      )
    end

    patch_item(receipt, item, { original_line_total: '220', line_total: '999' })

    aggregate_failures 'authority変更' do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 180, tax_amount: 18, total_amount: 198)
      expect(receipt.receipt_tax_details.sole).to have_attributes(
        rate: BigDecimal('0.1'),
        net_amount: 180,
        amount: 18
      )
      expect(item.reload).to have_attributes(
        original_line_total: 220,
        discount_rate: BigDecimal('0.1'),
        discount_amount: 22,
        line_total: 198
      )
    end
  end

  it 'original未記録positive-discount explicit rowのnon-amount partial編集で金額sourceと税証跡を保持する' do
    receipt, item = create_original_unrecorded_discounted_explicit_receipt
    before_receipt_amounts = receipt.attributes.slice(
      'subtotal_amount', 'tax_amount', 'total_amount', 'tax_rate'
    ).deep_dup
    before_profile = receipt.amount_calculation_profile.fetch('profile').deep_dup
    before_item_amounts = item.attributes.slice(
      'pricing_source_kind', 'original_line_total', 'discount_rate', 'discount_amount', 'line_total', 'tax_rate'
    ).deep_dup
    before_tax_details = receipt.receipt_tax_details.map { |detail| detail.attributes.deep_dup }

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => { id: item.id, confirmed_name: '名称だけ変更' }
        }
      }
    }

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(item.reload.confirmed_name).to eq('名称だけ変更')
      expect(item.attributes.slice(*before_item_amounts.keys)).to eq(before_item_amounts)
      expect(receipt.reload.attributes.slice(*before_receipt_amounts.keys)).to eq(before_receipt_amounts)
      expect(receipt.amount_calculation_profile.fetch('profile')).to eq(before_profile)
      expect(receipt.receipt_tax_details.map { |detail| detail.attributes.deep_dup }).to eq(before_tax_details)
    end
  end

  it 'original未記録positive-discount explicit rowのquantity partial編集で金額shapeを保持する' do
    receipt, item = create_original_unrecorded_discounted_explicit_receipt

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => { id: item.id, quantity: '2' }
        }
      }
    }

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 164, tax_amount: 16, total_amount: 180)
      expect(item.reload).to have_attributes(
        quantity: BigDecimal('2'),
        original_line_total: nil,
        discount_rate: BigDecimal('0.1'),
        discount_amount: 18,
        line_total: 180
      )
      expect(receipt.receipt_tax_details.sole).to have_attributes(
        rate: BigDecimal('0.1'),
        net_amount: 164,
        amount: 16
      )
    end
  end

  it 'original未記録positive-discount explicit rowのdiscount実変更を422にしてDBを保持する' do
    receipt, item = create_original_unrecorded_discounted_explicit_receipt
    before = persisted_graph_snapshot(receipt)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => { id: item.id, discount_rate: '20' }
        }
      }
    }

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(persisted_graph_snapshot(receipt)).to eq(before)
    end
  end

  it 'original未記録zero-only-discount explicit rowのnon-amount partial編集で物理shapeを保持する' do
    [
      { discount_rate: nil, discount_amount: nil },
      { discount_rate: BigDecimal('0'), discount_amount: 0 }
    ].each_with_index do |discounts, index|
      receipt, item = create_original_unrecorded_discounted_explicit_receipt
      item.update!(discounts)
      before = persisted_snapshot(receipt, item)

      patch receipt_path(receipt), params: {
        receipt: {
          lock_version: receipt.lock_version,
          receipt_items_attributes: {
            '0' => { id: item.id, confirmed_name: "0割引名称変更#{index}" }
          }
        }
      }

      after = persisted_snapshot(receipt, item)
      aggregate_failures discounts.inspect do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(item.reload.confirmed_name).to eq("0割引名称変更#{index}")
        expect(after[:item]).to eq(before[:item])
        expect(after[:receipt].except('lock_version')).to eq(before[:receipt].except('lock_version'))
      end
    end
  end

  it 'original未記録positive-discount explicit rowのfull-form blank authorityを422にしてDBを保持する' do
    receipt, item = create_original_unrecorded_discounted_explicit_receipt
    before = persisted_graph_snapshot(receipt)

    patch_item(
      receipt,
      item,
      {
        original_line_total: '',
        line_total: '999',
        discount_rate: '10'
      }
    )

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(persisted_graph_snapshot(receipt)).to eq(before)
    end
  end

  it 'original未記録positive-discount explicit rowは明示authorityから一度だけ割引を適用する' do
    receipt, item = create_original_unrecorded_discounted_explicit_receipt

    patch_item(
      receipt,
      item,
      {
        original_line_total: '220',
        line_total: '999',
        discount_rate: '10'
      }
    )

    aggregate_failures '正数authority' do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 180, tax_amount: 18, total_amount: 198)
      expect(item.reload).to have_attributes(
        original_line_total: 220,
        discount_rate: BigDecimal('0.1'),
        discount_amount: 22,
        line_total: 198
      )
    end

    receipt, item = create_original_unrecorded_discounted_explicit_receipt
    patch_item(
      receipt,
      item,
      {
        original_line_total: '0',
        line_total: '999',
        discount_rate: '10'
      }
    )

    aggregate_failures '0円authority' do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 0, tax_amount: 0, total_amount: 0)
      expect(item.reload).to have_attributes(
        original_line_total: 0,
        discount_rate: BigDecimal('0.1'),
        discount_amount: 0,
        line_total: 0
      )
    end
  end

  it 'discount sourceが残るformulaからexplicitへの曖昧な切替を422にしてDBを維持する' do
    receipt, item = create_reference_receipt(
      line_total: 162,
      subtotal_amount: 162,
      total_amount: 162
    )
    item.update!(
      original_line_total: 180,
      discount_amount: 18,
      discount_rate: BigDecimal('0.1'),
      line_total: 162
    )
    before = persisted_snapshot(receipt, item)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => {
            id: item.id,
            pricing_source_kind: 'explicit_line_total',
            original_line_total: '200',
            line_total: '999'
          }
        }
      }
    }

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(persisted_snapshot(receipt, item)).to eq(before)
    end
  end

  it 'formulaからexplicitへの明示intentでdiscount sourceをatomicに解除する' do
    receipt, item = create_reference_receipt(
      line_total: 162,
      subtotal_amount: 162,
      total_amount: 162
    )
    item.update!(
      original_line_total: 180,
      discount_amount: 18,
      discount_rate: BigDecimal('0.1'),
      line_total: 162
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => {
            id: item.id,
            pricing_source_kind: 'explicit_line_total',
            original_line_total: '200',
            line_total: '999',
            discount_rate: '',
            discount_amount: '999999',
            clear_item_discount_before_explicit: '1'
          }
        }
      }
    }

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 200, tax_amount: 0, total_amount: 200)
      expect(item.reload).to have_attributes(
        pricing_source_kind: 'explicit_line_total',
        original_line_total: 200,
        line_total: 200,
        discount_rate: nil,
        discount_amount: nil
      )
    end
  end

  it 'formulaの旧discount解除確認後に入力したexplicit discount rateを新sourceとして保存する' do
    receipt, item = create_reference_receipt(
      line_total: 162,
      subtotal_amount: 162,
      total_amount: 162
    )
    item.update!(
      original_line_total: 180,
      discount_amount: 18,
      discount_rate: BigDecimal('0.1'),
      line_total: 162
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => {
            id: item.id,
            pricing_source_kind: 'explicit_line_total',
            original_line_total: '200',
            line_total: '999',
            discount_rate: '10',
            discount_amount: '999999',
            clear_item_discount_before_explicit: '1'
          }
        }
      }
    }

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 180, tax_amount: 0, total_amount: 180)
      expect(item.reload).to have_attributes(
        pricing_source_kind: 'explicit_line_total',
        original_line_total: 200,
        line_total: 180,
        discount_rate: BigDecimal('0.1'),
        discount_amount: 20
      )
    end
  end

  it 'formulaからexplicitへの確認済みdiscount解除intentを422再表示後も保持する' do
    receipt, item = create_reference_receipt(
      line_total: 162,
      subtotal_amount: 162,
      total_amount: 162
    )
    item.update!(
      original_line_total: 180,
      discount_amount: 18,
      discount_rate: BigDecimal('0.1'),
      line_total: 162
    )
    before = persisted_graph_snapshot(receipt)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        memo: 'x' * 1_001,
        receipt_items_attributes: {
          '0' => {
            id: item.id,
            pricing_source_kind: 'explicit_line_total',
            original_line_total: '200',
            line_total: '999',
            discount_rate: '10',
            clear_item_discount_before_explicit: '1'
          }
        }
      }
    }

    document = Nokogiri::HTML(response.body)
    rendered_item = document.at_css("input[name$='[receipt_items_attributes][0][id]'][value='#{item.id}']")&.ancestors('div')&.find do |node|
      node['data-receipt-form-target'] == 'itemRow'
    end
    clear_intent = rendered_item&.at_css("input[name$='[clear_item_discount_before_explicit]']")
    explicit_source = rendered_item&.css("input[name$='[original_line_total]']")&.find do |input|
      input['disabled'].nil?
    end
    discount_rate = rendered_item&.at_css("input[name$='[discount_rate]']")

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(clear_intent&.[]('value')).to eq('1')
      expect(explicit_source&.[]('value')).to eq('200')
      expect(discount_rate&.[]('value')).to eq('10')
      expect(persisted_graph_snapshot(receipt)).to eq(before)
    end
  end

  it 'discount解除intentが未確認ならformula sourceとdiscountを一切変更しない' do
    receipt, item = create_reference_receipt(
      line_total: 162,
      subtotal_amount: 162,
      total_amount: 162
    )
    item.update!(
      original_line_total: 180,
      discount_amount: 18,
      discount_rate: BigDecimal('0.1'),
      line_total: 162
    )
    before = persisted_graph_snapshot(receipt)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => {
            id: item.id,
            pricing_source_kind: 'explicit_line_total',
            original_line_total: '200',
            line_total: '999',
            clear_item_discount_before_explicit: '0'
          }
        }
      }
    }

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(persisted_graph_snapshot(receipt)).to eq(before)
    end
  end

  it 'absolute discountだけをsourceに持つitemの非金額編集で派生discount rateを保存しない' do
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      subtotal_amount: 90,
      tax_amount: 0,
      total_amount: 90,
      review_reasons: []
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '値引商品',
      quantity: BigDecimal('1'),
      quantity_unit_code: 'each',
      pricing_source_kind: 'explicit_line_total',
      original_line_total: 100,
      discount_amount: 10,
      discount_rate: nil,
      line_total: 90,
      tax_rate: BigDecimal('0')
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => { id: item.id, confirmed_name: '名称だけ変更した値引商品' }
        }
      }
    }

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 90, tax_amount: 0, total_amount: 90)
      expect(item.reload).to have_attributes(
        confirmed_name: '名称だけ変更した値引商品',
        original_line_total: 100,
        discount_amount: 10,
        discount_rate: nil,
        line_total: 90
      )
    end
  end

  it '通常form相当の全項目保存でもabsolute discountの表示用rateをsourceへ昇格させない' do
    receipt, item = create_reference_receipt(
      line_total: 150,
      subtotal_amount: 150,
      total_amount: 150
    )
    item.update!(original_line_total: 180, discount_amount: 30, discount_rate: nil, line_total: 150)

    patch_item(
      receipt,
      item,
      {
        confirmed_name: '全項目保存した値引商品',
        discount_rate: item.discount_rate_percentage_input
      }
    )

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 150, tax_amount: 0, total_amount: 150)
      expect(item.reload).to have_attributes(
        confirmed_name: '全項目保存した値引商品',
        original_line_total: 180,
        discount_amount: 30,
        discount_rate: nil,
        line_total: 150
      )
    end
  end

  it 'absolute discountを維持したままreference basisを変更して戻すとsourceと金額が元へ戻る' do
    receipt, item = create_reference_receipt(
      line_total: 150,
      subtotal_amount: 150,
      total_amount: 150
    )
    item.update!(original_line_total: 180, discount_amount: 30, discount_rate: nil, line_total: 150)
    original_source = persisted_snapshot(receipt, item)

    patch_item(
      receipt,
      item,
      {
        reference_price_amount: '240',
        discount_rate: item.discount_rate_percentage_input
      }
    )

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 330, tax_amount: 0, total_amount: 330)
      expect(item.reload).to have_attributes(
        reference_price_amount: BigDecimal('240'),
        original_line_total: 360,
        discount_amount: 30,
        discount_rate: nil,
        line_total: 330
      )
    end

    patch_item(
      receipt,
      item,
      {
        reference_price_amount: '120',
        discount_rate: item.discount_rate_percentage_input
      }
    )

    final_source = persisted_snapshot(receipt, item)
    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 150, tax_amount: 0, total_amount: 150)
      expect(item.reload).to have_attributes(
        reference_price_amount: BigDecimal('120'),
        original_line_total: 180,
        discount_amount: 30,
        discount_rate: nil,
        line_total: 150
      )
      expect(final_source[:item]).to eq(original_source[:item])
      expect(final_source[:receipt].except('lock_version')).to eq(original_source[:receipt].except('lock_version'))
    end
  end

  it 'non-amount partial PATCHで未送信のreference metadataとderivedを保持する' do
    receipt, item = create_reference_receipt
    before = persisted_snapshot(receipt, item)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => { id: item.id, confirmed_name: '名称だけ変更' }
        }
      }
    }

    after = persisted_snapshot(receipt, item)

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(item.confirmed_name).to eq('名称だけ変更')
      expect(after[:item]).to eq(before[:item])
      expect(after[:receipt].except('lock_version')).to eq(before[:receipt].except('lock_version'))
    end
  end

  it 'non-amount partial PATCHでauthority-free raw evidenceと明示totalを再計算せず保持する' do
    receipt = create(
      :receipt,
      user: user,
      status: 'review_needed',
      subtotal_amount: 100,
      tax_amount: 0,
      total_amount: 100,
      review_reasons: []
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '未対応単位商品',
      price: 100,
      quantity: BigDecimal('2'),
      quantity_unit_code: 'each',
      quantity_unit_raw: 'bundle',
      reference_price_amount: BigDecimal('100'),
      reference_quantity: BigDecimal('2'),
      reference_quantity_unit_code: nil,
      reference_quantity_unit_raw: 'bundle-size',
      pricing_source_kind: nil,
      original_line_total: 100,
      line_total: 100,
      needs_review: true,
      review_reasons: []
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => { id: item.id, confirmed_name: '表示名だけ変更' }
        }
      }
    }

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: 100, tax_amount: 0, total_amount: 100)
      expect(item.reload).to have_attributes(
        confirmed_name: '表示名だけ変更',
        price: 100,
        quantity: BigDecimal('2'),
        quantity_unit_raw: 'bundle',
        reference_price_amount: BigDecimal('100'),
        reference_quantity: BigDecimal('2'),
        reference_quantity_unit_raw: 'bundle-size',
        pricing_source_kind: nil,
        original_line_total: 100,
        line_total: 100
      )
    end
  end

  it '金額未確定のauthority-free diagnostic rowを非金額編集してもnilを0円へ変えない' do
    receipt = create(
      :receipt,
      :with_image,
      user: user,
      status: 'review_needed',
      subtotal_amount: nil,
      tax_amount: nil,
      total_amount: nil,
      review_reasons: [ 'insufficient_data' ]
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '金額未確定の診断商品',
      price: 100,
      quantity: BigDecimal('2'),
      quantity_unit_code: 'each',
      reference_price_amount: BigDecimal('100'),
      reference_quantity: BigDecimal('2'),
      reference_quantity_unit_code: 'each',
      reference_price_tax_inclusion: 'gross',
      pricing_source_kind: nil,
      original_line_total: nil,
      line_total: nil,
      needs_review: true,
      review_reasons: [ 'item_amount_missing' ]
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => { id: item.id, confirmed_name: '名称だけ変更した診断商品' }
        }
      }
    }

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: nil, tax_amount: nil, total_amount: nil)
      expect(item.reload).to have_attributes(
        confirmed_name: '名称だけ変更した診断商品',
        original_line_total: nil,
        line_total: nil,
        pricing_source_kind: nil,
        reference_price_amount: BigDecimal('100'),
        reference_quantity: BigDecimal('2'),
        reference_quantity_unit_code: 'each',
        reference_price_tax_inclusion: 'gross'
      )
    end
  end

  it 'authority-free diagnostic rowの片側nilな金額形状を非金額編集で変更しない' do
    cases = [
      { original_line_total: nil, line_total: 100, receipt_total: 100 },
      { original_line_total: 100, line_total: nil, receipt_total: nil }
    ]

    cases.each_with_index do |test_case, index|
      receipt = create(
        :receipt,
        :with_image,
        user: user,
        status: 'review_needed',
        subtotal_amount: test_case[:receipt_total],
        tax_amount: test_case[:receipt_total]&.*(0),
        total_amount: test_case[:receipt_total],
        review_reasons: [ 'insufficient_data' ]
      )
      item = receipt.receipt_items.create!(
        confirmed_name: "片側未確定の診断商品#{index}",
        price: 100,
        quantity: BigDecimal('2'),
        quantity_unit_code: 'each',
        reference_price_amount: BigDecimal('100'),
        reference_quantity: BigDecimal('2'),
        reference_quantity_unit_code: 'each',
        reference_price_tax_inclusion: 'gross',
        pricing_source_kind: nil,
        original_line_total: test_case[:original_line_total],
        line_total: test_case[:line_total],
        needs_review: true,
        review_reasons: [ 'item_amount_missing' ]
      )
      before = persisted_snapshot(receipt, item)

      patch receipt_path(receipt), params: {
        receipt: {
          lock_version: receipt.lock_version,
          receipt_items_attributes: {
            '0' => { id: item.id, confirmed_name: "名称だけ変更した診断商品#{index}" }
          }
        }
      }

      after = persisted_snapshot(receipt, item)
      aggregate_failures test_case.inspect do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(after[:receipt].except('lock_version')).to eq(before[:receipt].except('lock_version'))
        expect(after[:item]).to eq(before[:item])
        expect(item.confirmed_name).to eq("名称だけ変更した診断商品#{index}")
      end
    end
  end

  it '金額未確定のpricing source kind未記録measurement rowを非金額編集してもnilを0円へ変えない' do
    receipt = create(
      :receipt,
      :with_image,
      user: user,
      status: 'review_needed',
      subtotal_amount: nil,
      tax_amount: nil,
      total_amount: nil,
      review_reasons: [ 'insufficient_data' ]
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '金額未確定の旧計量商品',
      price: 100,
      quantity: BigDecimal('2'),
      quantity_unit_code: 'liter',
      pricing_source_kind: nil,
      original_line_total: nil,
      line_total: nil,
      needs_review: true,
      review_reasons: [ 'item_amount_missing' ]
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => { id: item.id, confirmed_name: '名称だけ変更した旧計量商品' }
        }
      }
    }

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload).to have_attributes(subtotal_amount: nil, tax_amount: nil, total_amount: nil)
      expect(item.reload).to have_attributes(
        confirmed_name: '名称だけ変更した旧計量商品',
        pricing_source_kind: nil,
        original_line_total: nil,
        line_total: nil
      )
    end
  end

  it 'manual HTTPからauthority-free raw evidenceを作成せず422にする' do
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: 'raw unit拒否店',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '未対応単位商品',
              price: '100',
              quantity: '2',
              quantity_unit_code: 'each',
              quantity_unit_raw: 'bundle',
              original_line_total: '100',
              line_total: '100'
            }
          }
        }
      }
    end.not_to change(Receipt, :count)

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('receipts.form.errors.invalid_item_pricing_source'))
    end
  end

  it 'manual HTTPからauthority-free canonical diagnostic evidenceを作成せず422にする' do
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '診断情報拒否店',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '診断情報付き商品',
              price: '100',
              quantity: '2',
              quantity_unit_code: 'each',
              reference_price_amount: '100',
              reference_quantity: '2',
              reference_quantity_unit_code: 'each',
              reference_price_tax_inclusion: 'gross',
              original_line_total: '100',
              line_total: '100'
            }
          }
        }
      }
    end.not_to change(Receipt, :count)

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('receipts.form.errors.invalid_item_pricing_source'))
    end
  end

  it 'manual HTTPから保存済みauthority-free diagnostic evidenceを空にせずDBを維持する' do
    receipt = create(
      :receipt,
      user: user,
      status: 'review_needed',
      subtotal_amount: 100,
      tax_amount: 0,
      total_amount: 100,
      review_reasons: []
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '診断情報付き商品',
      price: 100,
      quantity: BigDecimal('2'),
      quantity_unit_code: 'each',
      reference_price_amount: BigDecimal('100'),
      reference_quantity: BigDecimal('2'),
      reference_quantity_unit_code: 'each',
      reference_price_tax_inclusion: 'gross',
      original_line_total: 100,
      line_total: 100,
      needs_review: true,
      review_reasons: []
    )
    before = persisted_snapshot(receipt, item)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => {
            id: item.id,
            reference_price_amount: '',
            reference_quantity: '',
            reference_quantity_unit_code: '',
            reference_price_tax_inclusion: ''
          }
        }
      }
    }

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(persisted_snapshot(receipt, item)).to eq(before)
    end
  end

  it 'authority-free diagnosticの金額source変更を422にしてkind未記録formulaへ昇格させない' do
    changes = [
      { price: '101' },
      { quantity: '3' },
      { quantity_unit_code: 'box' },
      { original_line_total: '100' },
      { line_total: '100' },
      { discount_rate: '10' }
    ]

    changes.each do |change|
      receipt = create(
        :receipt,
        :with_image,
        user: user,
        status: 'review_needed',
        subtotal_amount: nil,
        tax_amount: nil,
        total_amount: nil,
        review_reasons: [ 'insufficient_data' ]
      )
      item = receipt.receipt_items.create!(
        confirmed_name: '金額未確定の診断商品',
        price: 100,
        quantity: BigDecimal('2'),
        quantity_unit_code: 'each',
        reference_price_amount: BigDecimal('100'),
        reference_quantity: BigDecimal('2'),
        reference_quantity_unit_code: 'each',
        reference_price_tax_inclusion: 'gross',
        pricing_source_kind: nil,
        original_line_total: nil,
        line_total: nil,
        needs_review: true,
        review_reasons: [ 'item_amount_missing' ]
      )
      before = persisted_snapshot(receipt, item)

      patch receipt_path(receipt), params: {
        receipt: {
          lock_version: receipt.lock_version,
          receipt_items_attributes: {
            '0' => { id: item.id }.merge(change)
          }
        }
      }

      aggregate_failures change.inspect do
        expect(response).to have_http_status(:unprocessable_content)
        expect(persisted_snapshot(receipt, item)).to eq(before)
      end
    end
  end

  it 'manual createの不正sourceを422で1行だけ再表示し、DBへ保存しない' do
    presenters = []
    allow(ReceiptFormPresenter).to receive(:new).and_wrap_original do |original, **arguments|
      original.call(**arguments).tap { |presenter| presenters << presenter }
    end

    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '不正基準価格店',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '不完全な基準価格商品',
              quantity: '750',
              quantity_unit_code: 'milliliter',
              **reference_source_attributes(reference_quantity: '')
            }
          }
        }
      }
    end.not_to change(Receipt, :count)

    visible_names = presenters.last.visible_receipt_items.map(&:confirmed_name)
    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(visible_names).to eq([ '不完全な基準価格商品' ])
    end
  end

  it 'editへの不正な新規source rowを422で1行だけ再表示し、既存childrenを変更しない' do
    receipt, item = create_reference_receipt
    before = persisted_snapshot(receipt, item)
    presenters = []
    allow(ReceiptFormPresenter).to receive(:new).and_wrap_original do |original, **arguments|
      original.call(**arguments).tap { |presenter| presenters << presenter }
    end

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => item_attributes(item),
          '1' => {
            confirmed_name: '不正な追加基準価格商品',
            quantity: '1',
            quantity_unit_code: 'liter',
            **reference_source_attributes(reference_quantity_unit_code: 'gram')
          }
        }
      }
    }

    visible_names = presenters.last.visible_receipt_items.map(&:confirmed_name)
    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(visible_names).to contain_exactly('基準価格商品', '不正な追加基準価格商品')
      expect(visible_names.count('不正な追加基準価格商品')).to eq(1)
      expect(receipt.reload.receipt_items.count).to eq(1)
      expect(persisted_snapshot(receipt, item)).to eq(before)
    end
  end

  {
    'unknown authority kind' => { pricing_source_kind: 'unsupported' },
    'scientific reference amount' => { reference_price_amount: '1e2' },
    'raw purchased unit on formula authority' => { quantity_unit_raw: 'bundle' },
    'incomplete reference evidence' => { reference_quantity: '' }
  }.each do |label, invalid_attributes|
    it "#{label}を422にして保存済みsource/derived/lockを変更しない" do
      receipt, item = create_reference_receipt
      before = persisted_snapshot(receipt, item)

      patch_item(receipt, item, invalid_attributes)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(persisted_snapshot(receipt, item)).to eq(before)
      end
    end
  end

  it 'stale conflictでtyped sourceを再表示用に保持し、最新DB sourceとderivedを変更しない' do
    receipt, item = create_reference_receipt
    stale_lock_version = receipt.lock_version
    receipt.update!(memo: '別タブで保存済み')
    before = persisted_snapshot(receipt, item)
    presented_sources = []

    allow(ReceiptFormPresenter).to receive(:new).and_wrap_original do |original, **arguments|
      presented_sources << presented_source(arguments, item.id)
      original.call(**arguments)
    end

    patch_item(
      receipt,
      item,
      {
        reference_price_amount: '130',
        reference_quantity: '600',
        line_total: '999'
      },
      lock_version: stale_lock_version
    )

    presented = presented_sources.last

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('receipts.form.errors.stale_edit'))
      expect(BigDecimal(presented.fetch('reference_price_amount').to_s)).to eq(BigDecimal('130'))
      expect(BigDecimal(presented.fetch('reference_quantity').to_s)).to eq(BigDecimal('600'))
      expect(presented.fetch('pricing_source_kind')).to eq('reference_quantity_price')
      expect(persisted_snapshot(receipt, item)).to eq(before)
      expect(receipt.memo).to eq('別タブで保存済み')
    end
  end

  it 'Amount計算後のlock競合でもsource/derived/tax/profile/childrenを部分保存せずtyped sourceを再表示する' do
    receipt, item = create_reference_receipt(
      quantity: BigDecimal('1'),
      quantity_unit_code: 'liter',
      reference_price_amount: BigDecimal('110'),
      reference_quantity: BigDecimal('1'),
      reference_quantity_unit_code: 'liter',
      reference_price_tax_inclusion: 'net',
      tax_rate: BigDecimal('0.1'),
      line_total: 110,
      subtotal_amount: 110,
      tax_amount: 11,
      total_amount: 121,
      amount_calculation_profile: external_net_profile
    )
    receipt.receipt_tax_details.create!(rate: BigDecimal('0.1'), net_amount: 110, amount: 11)
    submitted_lock_version = receipt.lock_version
    concurrent_snapshot = nil
    presented_sources = []

    allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **arguments|
      original.call(**arguments).tap do
        next unless concurrent_snapshot.nil? && arguments.fetch(:context) == :edit_save

        Receipt.find(receipt.id).update!(memo: 'Amount計算後に別保存')
        concurrent_snapshot = persisted_graph_snapshot(receipt)
      end
    end
    allow(ReceiptFormPresenter).to receive(:new).and_wrap_original do |original, **arguments|
      presented_sources << presented_source(arguments, item.id)
      original.call(**arguments)
    end

    patch_item(
      receipt,
      item,
      {
        reference_price_amount: '130',
        reference_quantity: '0.5',
        line_total: '999',
        original_line_total: '998'
      },
      lock_version: submitted_lock_version
    )

    presented = presented_sources.last

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('receipts.form.errors.stale_edit'))
      expect(BigDecimal(presented.fetch('reference_price_amount').to_s)).to eq(BigDecimal('130'))
      expect(BigDecimal(presented.fetch('reference_quantity').to_s)).to eq(BigDecimal('0.5'))
      expect(presented.fetch('reference_price_tax_inclusion')).to eq('net')
      expect(persisted_graph_snapshot(receipt)).to eq(concurrent_snapshot)
      expect(receipt).to have_attributes(
        memo: 'Amount計算後に別保存',
        lock_version: submitted_lock_version + 1,
        subtotal_amount: 110,
        tax_amount: 11,
        total_amount: 121
      )
    end
  end
end
