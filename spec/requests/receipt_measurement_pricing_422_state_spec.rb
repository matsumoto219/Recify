require 'rails_helper'

RSpec.describe 'Receipt measurement pricing 422 form state', type: :request do
  let(:user) { create(:user) }
  let(:uploaded_image) do
    Rack::Test::UploadedFile.new(
      Rails.root.join('spec/fixtures/files/receipt_sample.jpg'),
      'image/jpeg'
    )
  end

  before do
    sign_in user
  end

  def create_receipt_with_reference_item
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      store_name: '基準価格保存店',
      payment_method: 'cash',
      subtotal_amount: 180,
      tax_amount: 0,
      total_amount: 180,
      review_reasons: []
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '基準価格商品',
      quantity: BigDecimal('750'),
      quantity_unit_code: 'milliliter',
      original_line_total: 180,
      line_total: 180,
      tax_rate: BigDecimal('0'),
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: BigDecimal('120'),
      reference_quantity: BigDecimal('500'),
      reference_quantity_unit_code: 'milliliter',
      reference_price_tax_inclusion: 'gross',
      needs_review: false,
      review_reasons: []
    )

    [ receipt, item ]
  end

  def reference_item_attributes(item, overrides = {})
    {
      id: item.id,
      confirmed_name: item.confirmed_name,
      quantity: item.quantity.to_s('F'),
      quantity_unit_code: item.quantity_unit_code,
      original_line_total: item.original_line_total,
      line_total: item.line_total,
      pricing_source_kind: item.pricing_source_kind,
      reference_price_amount: item.reference_price_amount.to_s('F'),
      reference_quantity: item.reference_quantity.to_s('F'),
      reference_quantity_unit_code: item.reference_quantity_unit_code,
      reference_price_tax_inclusion: item.reference_price_tax_inclusion,
      _destroy: '0'
    }.merge(overrides)
  end

  def capture_presenter_arguments
    arguments = []
    allow(ReceiptFormPresenter).to receive(:new).and_wrap_original do |original, **kwargs|
      arguments << kwargs
      original.call(**kwargs)
    end
    arguments
  end

  def submitted_item_rows(arguments)
    arguments.fetch(:submitted_params).to_h
      .fetch('receipt_items_attributes')
      .to_h
      .values
  end

  def rendered_item_row(document, name)
    document.css('[data-receipt-form-target="itemRow"]').find do |row|
      row.at_css("input[name$='[confirmed_name]']")&.[]('value') == name
    end
  end

  it 'storage quotaの422でも入力中のreference sourceをPresenterへ渡す' do
    receipt, item = create_receipt_with_reference_item
    before = item.attributes.deep_dup
    presenters = capture_presenter_arguments
    user.update!(storage_limit_bytes: 1)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        image: uploaded_image,
        receipt_items_attributes: {
          '0' => reference_item_attributes(
            item,
            reference_price_amount: '130',
            reference_quantity: '600'
          )
        }
      }
    }

    submitted = submitted_item_rows(presenters.last).sole
    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(submitted['reference_price_amount']).to eq('130')
      expect(submitted['reference_quantity']).to eq('600')
      expect(submitted['pricing_source_kind']).to eq('reference_quantity_price')
      expect(item.reload.attributes).to eq(before)
    end
  end

  it 'duplicate nested child conflictの422でも全submitted source rowをPresenterへ渡す' do
    receipt, item = create_receipt_with_reference_item
    before = item.attributes.deep_dup
    presenters = capture_presenter_arguments

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => reference_item_attributes(item, reference_price_amount: '130'),
          '1' => reference_item_attributes(item, reference_price_amount: '140')
        }
      }
    }

    submitted = submitted_item_rows(presenters.last)
    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(submitted.map { |row| BigDecimal(row['reference_price_amount'].to_s) }).to contain_exactly(
        BigDecimal('130'),
        BigDecimal('140')
      )
      expect(submitted.map { |row| row['pricing_source_kind'] }.uniq).to eq([ 'reference_quantity_price' ])
      expect(item.reload.attributes).to eq(before)
    end
  end

  it 'input normalizationのInvalidItemSource 422をPresenterへ明示する' do
    receipt, item = create_receipt_with_reference_item
    presenters = capture_presenter_arguments

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => reference_item_attributes(item, pricing_source_kind: 'unsupported')
        }
      }
    }

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(presenters.last.fetch(:invalid_item_source)).to be(true)
      expect(presenters.last.fetch(:submitted_params).dig('receipt_items_attributes', '0', 'id')).to eq(item.id.to_s)
    end
  end

  it 'Amount EngineのInvalidItemSource 422もPresenterへ明示する' do
    receipt, item = create_receipt_with_reference_item
    presenters = capture_presenter_arguments
    allow(ReceiptAmountService).to receive(:call).and_raise(ReceiptAmountService::InvalidItemSourceError)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => reference_item_attributes(item, reference_price_amount: '130')
        }
      }
    }

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(presenters.last.fetch(:invalid_item_source)).to be(true)
      expect(
        BigDecimal(
          presenters.last.fetch(:submitted_params)
            .dig('receipt_items_attributes', '0', 'reference_price_amount')
            .to_s
        )
      ).to eq(BigDecimal('130'))
    end
  end

  it 'createの非互換reference source 422でraw百分率を保持し、修正再送で同じrateを保存する' do
    presenters = capture_presenter_arguments
    submitted_receipt = {
      store_name: '百分率再送店',
      payment_method: 'cash',
      tax_rate: '0.10',
      receipt_items_attributes: {
        '0' => {
          confirmed_name: '百分率再送商品',
          quantity: '1.5',
          quantity_unit_code: 'liter',
          tax_rate: '10',
          discount_rate: '5.5',
          pricing_source_kind: 'reference_quantity_price',
          reference_price_amount: '120',
          reference_quantity: '500',
          reference_quantity_unit_code: 'gram',
          reference_price_tax_inclusion: 'gross'
        }
      }
    }

    expect do
      post receipts_path, params: { receipt: submitted_receipt }
    end.not_to change(Receipt, :count)

    document = Nokogiri::HTML(response.body)
    rendered_item = rendered_item_row(document, '百分率再送商品')
    rendered_tax_rate = rendered_item&.at_css('[data-receipt-form-target="taxRateInput"]')&.[]('value')
    rendered_discount_rate = rendered_item&.at_css('[data-receipt-form-target="discountRateInput"]')&.[]('value')
    presented = presenters.last.fetch(:submitted_params)

    aggregate_failures '422 response' do
      expect(response).to have_http_status(:unprocessable_content)
      expect(presented['tax_rate']).to eq('0.10')
      expect(presented.dig('receipt_items_attributes', '0', 'tax_rate')).to eq('10')
      expect(presented.dig('receipt_items_attributes', '0', 'discount_rate')).to eq('5.5')
      expect(rendered_tax_rate).to eq('10')
      expect(rendered_discount_rate).to eq('5.5')
    end

    corrected_receipt = submitted_receipt.deep_dup
    corrected_receipt[:receipt_items_attributes]['0'][:reference_quantity_unit_code] = 'milliliter'
    corrected_receipt[:receipt_items_attributes]['0'][:tax_rate] = rendered_tax_rate
    corrected_receipt[:receipt_items_attributes]['0'][:discount_rate] = rendered_discount_rate

    expect do
      post receipts_path, params: { receipt: corrected_receipt }
    end.to change(Receipt, :count).by(1)

    saved_item = user.receipts.find_by!(store_name: '百分率再送店').receipt_items.sole
    aggregate_failures 'corrected resubmission' do
      expect(response).to redirect_to(receipts_path)
      expect(saved_item.tax_rate).to eq(BigDecimal('0.1'))
      expect(saved_item.discount_rate).to eq(BigDecimal('0.055'))
    end
  end

  [
    [ 'Amount domain error', :domain_error ],
    [ 'stale conflict', :stale_conflict ]
  ].each do |label, failure_kind|
    it "#{label}のupdate 422でitem/adjustment/receiptのraw百分率を保持しDBを変更しない" do
      receipt, item = create_receipt_with_reference_item
      adjustment = receipt.receipt_adjustments.create!(
        kind: 'coupon',
        label: '保存済みクーポン',
        amount: 10,
        sign: 'discount',
        source: 'manual',
        tax_rate: BigDecimal('0.08'),
        needs_review: false,
        review_reasons: []
      )
      submitted_lock_version = receipt.lock_version
      receipt.update!(memo: '別タブで保存済み') if failure_kind == :stale_conflict
      before_receipt = receipt.reload.attributes.deep_dup
      before_item = item.reload.attributes.deep_dup
      before_adjustment = adjustment.reload.attributes.deep_dup
      presenters = capture_presenter_arguments

      patch receipt_path(receipt), params: {
        receipt: {
          lock_version: submitted_lock_version,
          tax_rate: '0.10',
          receipt_items_attributes: {
            '0' => reference_item_attributes(
              item,
              quantity_unit_code: failure_kind == :domain_error ? 'liter' : 'milliliter',
              reference_quantity_unit_code: failure_kind == :domain_error ? 'gram' : 'milliliter',
              tax_rate: '10.0',
              discount_rate: '5.5'
            )
          },
          receipt_adjustments_attributes: {
            '0' => {
              id: adjustment.id,
              kind: adjustment.kind,
              label: adjustment.label,
              amount: adjustment.amount,
              sign: adjustment.sign,
              tax_rate: '8.0',
              _destroy: '0'
            }
          }
        }
      }

      presented = presenters.last.fetch(:submitted_params)
      document = Nokogiri::HTML(response.body)
      rendered_item = rendered_item_row(document, item.confirmed_name)
      rendered_adjustment = document.css('[data-receipt-form-target="adjustmentRow"]').find do |row|
        row.at_css("input[name$='[id]']")&.[]('value') == adjustment.id.to_s
      end
      aggregate_failures label do
        expect(response).to have_http_status(:unprocessable_content)
        expect(presented['tax_rate']).to eq('0.10')
        expect(presented.dig('receipt_items_attributes', '0', 'tax_rate')).to eq('10.0')
        expect(presented.dig('receipt_items_attributes', '0', 'discount_rate')).to eq('5.5')
        expect(presented.dig('receipt_adjustments_attributes', '0', 'tax_rate')).to eq('8.0')
        expect(rendered_item&.at_css('[data-receipt-form-target="taxRateInput"]')&.[]('value')).to eq('10.0')
        expect(rendered_item&.at_css('[data-receipt-form-target="discountRateInput"]')&.[]('value')).to eq('5.5')
        expect(rendered_adjustment&.at_css('[data-receipt-form-target="adjustmentTaxRateInput"]')&.[]('value')).to eq('8.0')
        expect(receipt.reload.attributes).to eq(before_receipt)
        expect(item.reload.attributes).to eq(before_item)
        expect(adjustment.reload.attributes).to eq(before_adjustment)
      end
    end
  end

  it 'InvalidItemSource以外の422ではPresenter flagを立てない' do
    receipt, item = create_receipt_with_reference_item
    presenters = capture_presenter_arguments
    user.update!(storage_limit_bytes: 1)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        image: uploaded_image,
        receipt_items_attributes: {
          '0' => reference_item_attributes(item)
        }
      }
    }

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(presenters.last.fetch(:invalid_item_source)).to be(false)
    end
  end

  it 'stale conflictでformulaからexplicitへのdiscount置換入力をraw percentageのまま再送できる' do
    receipt, item = create_receipt_with_reference_item
    item.update!(
      original_line_total: 180,
      discount_rate: BigDecimal('0.1'),
      discount_amount: 18,
      line_total: 162
    )
    receipt.update!(subtotal_amount: 162, total_amount: 162)
    stale_lock_version = receipt.lock_version
    receipt.update!(memo: '別保存')

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: stale_lock_version,
        receipt_items_attributes: {
          '0' => reference_item_attributes(
            item,
            pricing_source_kind: 'explicit_line_total',
            original_line_total: '200',
            line_total: '999',
            discount_rate: '10',
            clear_item_discount_before_explicit: '1'
          )
        }
      }
    }

    document = Nokogiri::HTML(response.body)
    rendered_item = document.css('[data-receipt-form-target="itemRow"]').find do |row|
      row.at_css("input[name$='[id]']")&.[]('value') == item.id.to_s
    end
    rendered_original = rendered_item&.css("input[name$='[original_line_total]']")&.find do |input|
      input['disabled'].nil?
    end
    rendered_rate = rendered_item&.at_css("input[name$='[discount_rate]']")
    rendered_clear_intent = rendered_item&.at_css("input[name$='[clear_item_discount_before_explicit]']")

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(rendered_original&.[]('value')).to eq('200')
      expect(rendered_rate&.[]('value')).to eq('10')
      expect(rendered_clear_intent&.[]('value')).to eq('1')
      expect(item.reload).to have_attributes(
        pricing_source_kind: 'reference_quantity_price',
        original_line_total: 180,
        discount_rate: BigDecimal('0.1'),
        discount_amount: 18,
        line_total: 162
      )
    end

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.reload.lock_version,
        receipt_items_attributes: {
          '0' => reference_item_attributes(
            item,
            pricing_source_kind: 'explicit_line_total',
            original_line_total: rendered_original&.[]('value'),
            line_total: '999',
            discount_rate: rendered_rate&.[]('value'),
            clear_item_discount_before_explicit: rendered_clear_intent&.[]('value')
          )
        }
      }
    }

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(item.reload).to have_attributes(
        pricing_source_kind: 'explicit_line_total',
        original_line_total: 200,
        discount_rate: BigDecimal('0.1'),
        discount_amount: 20,
        line_total: 180
      )
    end
  end

  it 'stale conflictの422で曖昧なexplicit行の保存済みpositive rateを推測解除しない' do
    receipt, item = create_receipt_with_reference_item
    item.update_columns(
      pricing_source_kind: 'explicit_line_total',
      reference_price_amount: nil,
      reference_quantity: nil,
      reference_quantity_unit_code: nil,
      reference_price_tax_inclusion: nil,
      original_line_total: nil,
      line_total: 180,
      discount_rate: BigDecimal('0.1'),
      discount_amount: nil
    )
    stale_lock_version = receipt.lock_version
    receipt.update!(memo: '別保存')

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: stale_lock_version,
        receipt_items_attributes: {
          '0' => {
            id: item.id,
            confirmed_name: item.confirmed_name,
            quantity: item.quantity.to_s('F'),
            quantity_unit_code: item.quantity_unit_code,
            pricing_source_kind: 'explicit_line_total',
            original_line_total: '',
            line_total: '180',
            discount_rate: '',
            clear_item_discount_before_explicit: '0',
            _destroy: '0'
          }
        }
      }
    }

    document = Nokogiri::HTML(response.body)
    rendered_item = document.css('[data-receipt-form-target="itemRow"]').find do |row|
      row.at_css("input[name$='[id]']")&.[]('value') == item.id.to_s
    end
    rendered_source = rendered_item&.css("input[name$='[original_line_total]']")&.find do |input|
      input['disabled'].nil?
    end
    rendered_summary = rendered_item&.at_css('[data-receipt-form-target="pricingSourceSummary"]:not([hidden])')
    rendered_line = rendered_item&.at_css('[data-receipt-form-target="lineTotalInput"]')

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(rendered_item&.[]('data-receipt-form-explicit-line-total-source-missing')).to eq('true')
      expect(rendered_source&.[]('value')).to be_nil
      expect(rendered_source&.[]('required')).to eq('required')
      expect(rendered_source&.[]('aria-label')).to eq('割引前明細金額')
      expect(rendered_summary&.text&.strip).to eq('割引前明細金額')
      expect(rendered_line&.[]('value')).to eq('180')
      expect(item.reload).to have_attributes(
        pricing_source_kind: 'explicit_line_total',
        original_line_total: nil,
        line_total: 180,
        discount_rate: BigDecimal('0.1'),
        discount_amount: nil
      )
    end
  end

  [
    [ 'invalid source', :invalid_source ],
    [ 'stale edit', :stale_edit ]
  ].each do |label, failure_kind|
    it "#{label}の422で保存済み明細の_destroy操作をhidden行として保持する" do
      receipt, item = create_receipt_with_reference_item
      destroyed_item = receipt.receipt_items.create!(
        confirmed_name: '削除中の商品',
        quantity: 1,
        quantity_unit_code: 'each',
        original_line_total: 50,
        line_total: 50,
        tax_rate: BigDecimal('0'),
        needs_review: false,
        review_reasons: []
      )
      submitted_lock_version = receipt.lock_version
      receipt.update!(memo: '別保存') if failure_kind == :stale_edit
      before = receipt.reload.attributes.deep_dup

      patch receipt_path(receipt), params: {
        receipt: {
          lock_version: submitted_lock_version,
          receipt_items_attributes: {
            '0' => reference_item_attributes(
              item,
              pricing_source_kind: failure_kind == :invalid_source ? 'unsupported' : item.pricing_source_kind,
              reference_price_amount: '130'
            ),
            '1' => {
              id: destroyed_item.id,
              _destroy: '1'
            }
          }
        }
      }

      document = Nokogiri::HTML(response.body)
      visible_ids = document.css('[data-receipt-form-target="itemRow"] input[name$="[id]"]')
        .map { |input| input['value'] }
      destroy_input = document.at_css(
        "input[name='receipt[receipt_items_attributes][destroy_#{destroyed_item.id}][_destroy]']"
      )

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(visible_ids).not_to include(destroyed_item.id.to_s)
        expect(destroy_input&.[]('value')).to eq('1')
        expect(receipt.reload.attributes).to eq(before)
        expect(ReceiptItem.exists?(destroyed_item.id)).to be(true)
      end
    end
  end
end
