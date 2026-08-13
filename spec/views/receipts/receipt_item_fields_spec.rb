require 'rails_helper'

RSpec.describe 'receipts/_receipt_item_fields', type: :view do
  def render_item(item, new_record: item.new_record?, submitted_params: nil, pricing_source_details_open: false)
    presenter = ReceiptFormPresenter.new(receipt: item.receipt, submitted_params: submitted_params)
    form_builder = ActionView::Helpers::FormBuilder.new(
      'receipt[receipt_items_attributes][0]',
      item,
      view,
      {}
    )

    render partial: 'receipts/receipt_item_fields', locals: {
      item_form: form_builder,
      item: item,
      new_record: new_record,
      row_state: presenter.item_row(item, new_record: new_record),
      pricing_source_details_open: pricing_source_details_open
    }

    Nokogiri::HTML.fragment(rendered)
  end

  it '3つの計算方式を共通の金額cellで切り替える' do
    receipt = build(:receipt)
    item = receipt.receipt_items.build

    document = render_item(item)
    amount_cell = document.at_css('[data-receipt-item-amount-cell]')

    aggregate_failures do
      expect(amount_cell).to be_present
      expect(amount_cell.css('[data-receipt-form-target="pricingModePanel"]')).to contain_exactly(
        satisfy { |panel| panel['data-receipt-form-pricing-modes'] == 'count_unit_price unclassified' },
        satisfy { |panel| panel['data-receipt-form-pricing-modes'] == 'reference_quantity_price' },
        satisfy { |panel| panel['data-receipt-form-pricing-modes'] == 'explicit_line_total' }
      )
      expect(amount_cell.css('[data-receipt-item-mobile-amount-label]').map { |label| label.text.strip }).to eq([ '金額' ])
      expect(document.css('[data-receipt-item-mobile-amount-label]').size).to eq(1)
      expect(amount_cell.at_css('.receipt-form-pricing-result')['class']).to include('flex')
      expect(amount_cell.at_css('.receipt-form-pricing-result')['class']).to include('h-[42px]')
    end
  end

  it '基準価格を通貨prefixなしの中央寄せとし、基準数量に既存のcompact単位表示を使う' do
    receipt = build(:receipt)
    item = receipt.receipt_items.build(pricing_source_kind: 'reference_quantity_price')

    document = render_item(item)
    reference_price = document.at_css('[data-receipt-form-target="referencePriceAmountInput"]')
    reference_price_wrapper = reference_price.ancestors.find { |ancestor| ancestor['class'].to_s.split.include?('group') }
    reference_quantity = document.at_css('[data-receipt-form-target="referenceQuantityInput"]')
    reference_quantity_wrapper = reference_quantity.ancestors.find { |ancestor| ancestor['data-controller'] == 'number-field' }
    reference_unit = document.at_css('[data-receipt-form-target="referenceQuantityUnitInput"]')

    aggregate_failures do
      expect(reference_price['class']).to include('text-center')
      expect(reference_price_wrapper.xpath('./span').map(&:text)).not_to include('¥')
      expect(reference_quantity_wrapper['class']).to include('quantity-unit-number-field-mobile-center')
      expect(reference_unit['class']).to include('quantity-unit-number-field-centered-select')
    end
  end

  it '計算方式selectは中間幅で1行を使い、矢印と最長optionの表示幅を確保する' do
    receipt = build(:receipt)
    item = receipt.receipt_items.build

    document = render_item(item)
    pricing_grid = document.at_css('.receipt-form-pricing-source-fields > .grid')
    mode_select = document.at_css('[data-receipt-form-target="pricingSourceModeInput"]')
    mode_column = mode_select.ancestors.find { |ancestor| ancestor.parent == pricing_grid }
    mode_panels = pricing_grid.css('[data-receipt-form-target="pricingModePanel"]')

    aggregate_failures do
      expect(pricing_grid['class'].to_s.split).to include('grid-cols-1', '2xl:grid-cols-12')
      expect(pricing_grid['class'].to_s.split).not_to include('md:grid-cols-12')
      expect(pricing_grid.parent['class'].to_s.split).to include('p-3', 'max-[359px]:px-1')
      expect(mode_column['class'].to_s.split).to include('2xl:col-span-5')
      expect(mode_select['class'].to_s.split).to include('pr-10')
      expect(mode_panels).to all(
        satisfy { |panel| panel['class'].to_s.split.include?('2xl:col-span-7') }
      )
    end
  end

  it 'モバイルでは基準価格と直接入力だけに共通のサイドステッパーを表示する' do
    receipt = build(:receipt)
    item = receipt.receipt_items.build(pricing_source_kind: 'reference_quantity_price')

    document = render_item(item)
    reference_price = document.at_css('[data-receipt-form-target="referencePriceAmountInput"]')
    explicit_total = document.at_css('[data-receipt-form-target="explicitLineTotalInput"]')
    reference_price_label = I18n.t('receipts.item_fields.reference_price_amount')
    explicit_total_label = I18n.t('receipts.item_fields.explicit_line_total')
    reference_quantity_label = I18n.t('receipts.item_fields.reference_quantity')

    aggregate_failures do
      expect(document.at_css(%(button[aria-label="#{I18n.t('shared.number_field.decrement_aria', label: reference_price_label)}"])))
        .to be_present
      expect(document.at_css(%(button[aria-label="#{I18n.t('shared.number_field.increment_aria', label: reference_price_label)}"])))
        .to be_present
      expect(document.at_css(%(button[aria-label="#{I18n.t('shared.number_field.decrement_aria', label: explicit_total_label)}"])))
        .to be_present
      expect(document.at_css(%(button[aria-label="#{I18n.t('shared.number_field.increment_aria', label: explicit_total_label)}"])))
        .to be_present
      expect(document.css(%(button[aria-label*="#{reference_quantity_label}"]))).to be_empty
      expect(document.css('button.field-stepper-button')).to all(
        satisfy { |button| button['class'].to_s.split.include?('md:hidden') }
      )
      expect(reference_price['class'].to_s.split).to include('field-stepper-input', 'text-center')
      expect(explicit_total['class'].to_s.split).to include('field-stepper-input', 'text-center')
      expect(explicit_total['class'].to_s.split).not_to include('receipt-form-explicit-line-total-input')
      expect(explicit_total['data-receipt-form-decrement-label-with-discount']).to eq('割引前明細金額を減らす')
      expect(explicit_total['data-receipt-form-decrement-label-without-discount']).to eq('明細金額を減らす')
      expect(explicit_total['data-receipt-form-increment-label-with-discount']).to eq('割引前明細金額を増やす')
      expect(explicit_total['data-receipt-form-increment-label-without-discount']).to eq('明細金額を増やす')
    end
  end

  it '金額source fieldsを通常は閉じたnative detailsとしてauthority summaryの後に配置する' do
    receipt = build(:receipt)
    item = receipt.receipt_items.build

    document = render_item(item)
    row = document.at_css('[data-receipt-form-target="itemRow"]')
    authority_summary = row.at_css('.receipt-form-pricing-source-summary')
    item_details = row.at_css('[data-receipt-form-target="itemDetailsPanel"]')
    pricing_details = item_details.at_css('details[data-receipt-pricing-source-details]')
    pricing_summary = pricing_details.at_css('summary[data-receipt-pricing-source-summary]')
    content = pricing_details.at_css('[data-collapsible-details-target="content"]')
    pricing_arrow = pricing_summary.at_css('.material-symbols-outlined')
    pricing_summary_classes = pricing_summary['class'].to_s.split

    aggregate_failures do
      expect(pricing_details['data-receipt-pricing-source-details']).not_to be_nil
      expect(pricing_details['open']).to be_nil
      expect(pricing_summary.text.strip).to include('計算方式を変更')
      expect(pricing_summary_classes).to include(
        'btn-link-primary',
        'inline-flex',
        'gap-1',
        'focus-visible:ring-2',
        'token-focus-ring-brand'
      )
      expect(pricing_summary_classes).not_to include('w-full', 'justify-between', 'border', 'token-bg-input')
      expect(pricing_arrow.text.strip).to eq('expand_more')
      expect(pricing_arrow['class']).to include('group-open:rotate-180')
      expect(pricing_arrow['aria-hidden']).to eq('true')
      expect(content['aria-hidden']).to eq('true')
      expect(content).to have_attribute('inert')
      expect(row.element_children.index(authority_summary)).to be < row.element_children.index(item_details)
      expect(pricing_details.at_css('fieldset.receipt-form-pricing-source-fields')).to be_present
    end
  end

  it '税込基準badgeと説明文を同じ中央軸に揃える' do
    receipt = build(:receipt)
    item = receipt.receipt_items.build(pricing_source_kind: 'reference_quantity_price')

    document = render_item(item)
    tax_note = document.at_css('[data-receipt-reference-tax-note]')
    badge = tax_note.at_css('[data-receipt-reference-tax-badge]')
    description = tax_note.at_css('[data-receipt-reference-tax-description]')

    aggregate_failures do
      expect(tax_note['class']).to include('items-center')
      expect(tax_note['class']).not_to include('items-start')
      expect(badge['class']).to include('inline-flex', 'items-center')
      expect(badge['class']).not_to include('mt-0.5')
      expect(description.text.strip).to eq('この基準価格は税込金額として計算します。')
    end
  end

  it '金額sourceエラー再表示では計算方式detailsを開いた状態で描画する' do
    receipt = build(:receipt)
    item = receipt.receipt_items.build

    document = render_item(item, pricing_source_details_open: true)
    pricing_details = document.at_css('details[data-receipt-pricing-source-details]')
    content = pricing_details.at_css('[data-collapsible-details-target="content"]')

    aggregate_failures do
      expect(pricing_details).to have_attribute('open')
      expect(content['aria-hidden']).to eq('false')
      expect(content['inert']).to be_nil
    end
  end

  it '新規行は単価と数量modeを選択し、非選択sourceを送信しない' do
    receipt = build(:receipt)
    item = receipt.receipt_items.build

    document = render_item(item)
    mode_select = document.at_css('[data-receipt-form-target="pricingSourceModeInput"]')
    reference_panel = document.at_css('[data-receipt-form-pricing-modes="reference_quantity_price"]')

    aggregate_failures do
      expect(mode_select.at_css('option[selected]')['value']).to eq('count_unit_price')
      expect(document.at_css('[data-receipt-form-pricing-modes~="count_unit_price"]')['hidden']).to be_nil
      expect(reference_panel).to have_attribute('hidden')
      expect(reference_panel).to have_attribute('inert')
      expect(document.at_css('[data-receipt-form-target="referencePriceAmountInput"]')['disabled']).to eq('disabled')
      expect(document.at_css('[data-receipt-form-target="referencePriceTaxInclusionInput"]')['value']).to eq('gross')
      expect(document.at_css('[data-receipt-form-target="referencePriceTaxInclusionInput"]')['disabled']).to eq('disabled')
      expect(document.at_css('[data-receipt-form-target="explicitLineTotalInput"]')['name']).to end_with('[original_line_total]')
      expect(document.at_css('[data-receipt-form-target="explicitLineTotalInput"]')['disabled']).to eq('disabled')
      expect(document.css('input[name$="[original_line_total]"]:not([disabled])').size).to eq(1)
    end
  end

  it '参照価格modeでexact sourceと保存済み税抜基準を表示する' do
    receipt = build(:receipt)
    item = receipt.receipt_items.build(
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: BigDecimal('120.5'),
      reference_quantity: BigDecimal('0.5'),
      reference_quantity_unit_code: 'liter',
      reference_price_tax_inclusion: 'net',
      quantity: BigDecimal('1.25'),
      quantity_unit_code: 'liter',
      line_total: 332
    )

    document = render_item(item, new_record: false)
    reference_panel = document.at_css('[data-receipt-form-pricing-modes="reference_quantity_price"]')
    summary = document.at_css('[data-receipt-form-target="pricingSourceSummary"]:not([hidden])')

    aggregate_failures do
      expect(reference_panel['hidden']).to be_nil
      expect(document.at_css('[data-receipt-form-target="referencePriceAmountInput"]')['value']).to eq('120.5')
      expect(document.at_css('[data-receipt-form-target="referenceQuantityInput"]')['value']).to eq('0.5')
      expect(document.at_css('[data-receipt-form-target="referenceQuantityUnitInput"] option[selected]')['value']).to eq('liter')
      expect(document.at_css('[data-receipt-form-target="referencePriceTaxInclusionInput"]')['value']).to eq('net')
      expect(document.text).to include('税抜基準')
      expect(summary.text.strip).to eq('120.5円 / 0.5L（税抜）')
      expect(document.at_css('[data-receipt-form-target="priceInput"]')['disabled']).to eq('disabled')
    end
  end

  it '明示金額modeで割引前sourceと割引解除確認intentをderived totalから分離する' do
    receipt = build(:receipt)
    item = receipt.receipt_items.build(
      pricing_source_kind: 'explicit_line_total',
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 200,
      line_total: 180,
      discount_amount: 20
    )

    document = render_item(item, new_record: false)
    explicit_input = document.at_css('[data-receipt-form-target="explicitLineTotalInput"]')
    explicit_help = document.at_css('[data-receipt-form-target="explicitLineTotalHelp"]')
    line_total_inputs = document.css('input[name$="[line_total]"]')
    clear_intent = document.at_css('[data-receipt-form-target="clearItemDiscountBeforeExplicitInput"]')

    aggregate_failures do
      expect(explicit_input['value']).to eq('200')
      expect(explicit_input['name']).to end_with('[original_line_total]')
      expect(explicit_input['aria-label']).to eq('割引前明細金額')
      expect(line_total_inputs.size).to eq(1)
      expect(line_total_inputs.first['type']).to eq('hidden')
      expect(document.css('input[name$="[original_line_total]"]:not([disabled])')).to contain_exactly(explicit_input)
      expect(clear_intent['name']).to end_with('[clear_item_discount_before_explicit]')
      expect(clear_intent['value']).to eq('0')
      discount_source_row = document.at_css('[data-receipt-form-has-persisted-absolute-discount-source]')
      expect(discount_source_row['data-receipt-form-has-persisted-absolute-discount-source']).to eq('true')
      expect(explicit_help.text).to include('入力値に明細割引を1回適用')
      expect(explicit_help['data-receipt-form-text-with-discount']).to include('入力値に明細割引を1回適用')
      expect(explicit_help['data-receipt-form-text-without-discount']).to include('印字された明細金額')
    end
  end

  it '割引前source未記録の明示金額行は入力を空にして保存済みderived表示だけを維持する' do
    receipt = build(:receipt)
    item = receipt.receipt_items.build(
      pricing_source_kind: 'explicit_line_total',
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: nil,
      line_total: 180,
      discount_amount: 20
    )

    document = render_item(item, new_record: false)
    row = document.at_css('[data-receipt-form-target="itemRow"]')
    explicit_input = document.at_css('[data-receipt-form-target="explicitLineTotalInput"]')
    line_total_input = document.at_css('[data-receipt-form-target="lineTotalInput"]')
    formula_state = document.at_css('[data-receipt-form-target="originalLineTotalInput"]')
    summary = document.at_css('[data-receipt-form-target="pricingSourceSummary"]:not([hidden])')

    aggregate_failures do
      expect(row['data-receipt-form-explicit-line-total-source-missing']).to eq('true')
      expect(explicit_input['value']).to be_nil
      expect(explicit_input['required']).to eq('required')
      expect(explicit_input['aria-label']).to eq('割引前明細金額')
      expect(summary.text.strip).to eq('割引前明細金額')
      expect(line_total_input['value']).to eq('180')
      expect(line_total_input['data-original-line-total']).to be_nil
      expect(formula_state['value']).to be_nil
      expect(formula_state['disabled']).to eq('disabled')
      expect(document.css('[data-receipt-form-target="lineTotalDisplay"]')).to all(have_text('¥180'))
    end
  end

  it '422再表示で保存済みabsolute discountとその0円sourceを維持する' do
    receipt = create(:receipt)
    build_persisted_item = lambda do |name, discount_amount|
      receipt.receipt_items.create!(
        confirmed_name: name,
        pricing_source_kind: 'count_unit_price',
        price: 180,
        quantity: 1,
        quantity_unit_code: 'each',
        original_line_total: 180,
        line_total: 180
      ).tap do |item|
        item.update_columns(
          pricing_source_kind: 'explicit_line_total',
          price: nil,
          original_line_total: nil,
          line_total: 180,
          discount_rate: nil,
          discount_amount: discount_amount
        )
      end
    end
    positive_item = build_persisted_item.call('正の割引', 20)
    zero_item = build_persisted_item.call('0円割引', 0)

    render_with_discount_rate = lambda do |item, discount_rate|
      render_item(
        item,
        new_record: false,
        submitted_params: {
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              pricing_source_kind: 'explicit_line_total',
              original_line_total: '',
              discount_rate: discount_rate,
              clear_item_discount_before_explicit: '0'
            }
          }
        }
      )
    end

    positive_document = render_with_discount_rate.call(positive_item, '')
    zero_document = render_with_discount_rate.call(zero_item, '0')
    positive_row = positive_document.at_css('[data-receipt-form-target="itemRow"]')
    zero_row = zero_document.css('[data-receipt-form-target="itemRow"]').last

    aggregate_failures do
      expect(positive_row['data-receipt-form-has-persisted-absolute-discount-source']).to eq('true')
      expect(positive_row['data-receipt-form-explicit-line-total-source-missing']).to eq('true')
      expect(positive_document.at_css('[data-receipt-form-target="explicitLineTotalInput"]')['value']).to be_nil
      expect(positive_document.at_css('[data-receipt-form-target="pricingSourceSummary"]:not([hidden])').text.strip).to eq('割引前明細金額')
      expect(positive_document.at_css('[data-receipt-form-target="lineTotalInput"]')['value']).to eq('180')

      expect(zero_row['data-receipt-form-has-persisted-absolute-discount-source']).to eq('true')
      expect(zero_row['data-receipt-form-explicit-line-total-source-missing']).to eq('false')
      expect(zero_document.css('[data-receipt-form-target="explicitLineTotalInput"]').last['value']).to eq('180')
      expect(zero_document.css('[data-receipt-form-target="pricingSourceSummary"]:not([hidden])').last.text.strip).to eq('割引前明細金額 180円')
    end
  end

  it '422再表示で曖昧なexplicit行の保存済みpositive rateを維持する' do
    receipt = create(:receipt)
    item = receipt.receipt_items.create!(
      confirmed_name: '正率割引',
      pricing_source_kind: 'count_unit_price',
      price: 200,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 200,
      line_total: 180,
      discount_rate: BigDecimal('0.1'),
      discount_amount: nil
    )
    item.update_columns(
      pricing_source_kind: 'explicit_line_total',
      price: nil,
      original_line_total: nil
    )

    document = render_item(
      item,
      new_record: false,
      submitted_params: {
        receipt_items_attributes: {
          '0' => {
            id: item.id,
            pricing_source_kind: 'explicit_line_total',
            original_line_total: '',
            discount_rate: '',
            clear_item_discount_before_explicit: '0'
          }
        }
      }
    )
    row = document.at_css('[data-receipt-form-target="itemRow"]')

    aggregate_failures do
      expect(row['data-receipt-form-explicit-line-total-source-missing']).to eq('true')
      expect(document.at_css('[data-receipt-form-target="explicitLineTotalInput"]')['value']).to be_nil
      expect(document.at_css('[data-receipt-form-target="explicitLineTotalInput"]')['required']).to eq('required')
      expect(document.at_css('[data-receipt-form-target="explicitLineTotalInput"]')['aria-label']).to eq('割引前明細金額')
      expect(document.at_css('[data-receipt-form-target="pricingSourceSummary"]:not([hidden])').text.strip).to eq('割引前明細金額')
      expect(document.at_css('[data-receipt-form-target="lineTotalInput"]')['value']).to eq('180')
      expect(document.css('[data-receipt-form-target="lineTotalDisplay"]')).to all(have_text('¥180'))
    end
  end

  it 'authority kind未記録の保存済み行は実際の金額意味を表示し、自動backfillしない' do
    receipt = build(:receipt)
    item = receipt.receipt_items.build(
      price: 80,
      quantity: BigDecimal('1.5'),
      quantity_unit_code: 'liter',
      line_total: 120
    )

    document = render_item(item, new_record: false)
    mode_select = document.at_css('[data-receipt-form-target="pricingSourceModeInput"]')
    summary = document.at_css('[data-receipt-form-target="pricingSourceSummary"]:not([hidden])')

    aggregate_failures do
      expect(mode_select.at_css('option:first-child')['value']).to eq('')
      expect(summary.text.strip).to eq('保存済み明細金額 120円（方式未記録）')
    end
  end

  it '詳細toggleとpanel、金額根拠summaryをaccessible nameで関連付ける' do
    receipt = build(:receipt)
    item = receipt.receipt_items.build

    document = render_item(item)
    details = document.at_css('[data-receipt-form-target="itemDetailsPanel"]')
    toggles = document.css('[data-receipt-form-target="itemDetailsToggle"]')
    summary = document.at_css('[aria-live="polite"]')

    aggregate_failures do
      expect(details['id']).to be_present
      expect(toggles).not_to be_empty
      expect(toggles.map { |toggle| toggle['aria-controls'] }.uniq).to eq([ details['id'] ])
      expect(toggles).to all(satisfy { |toggle| toggle['aria-expanded'] == 'false' })
      expect(summary['aria-label']).to eq('金額の根拠')
      expect(summary.at_css('[data-receipt-form-target="pricingSourceSummary"]')['class']).to include('break-words')
      expect(summary.at_css('[data-receipt-form-target="pricingSourceSummary"]')['class']).not_to include('truncate')
      expect(document.at_css('label[for$="_pricing_source_kind"]')).to be_present
      expect(document.css('[id]').map { |element| element['id'] }).to eq(
        document.css('[id]').map { |element| element['id'] }.uniq
      )
    end
  end
end
