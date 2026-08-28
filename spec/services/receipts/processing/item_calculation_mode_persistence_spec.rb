require 'rails_helper'

RSpec.describe 'OCR item calculation mode persistence' do
  def ocr_fixture(name)
    raw = JSON.parse(Rails.root.join("spec/fixtures/ocr/#{name}.json").read)

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def finalize_decision(strategy, error_code: nil, ocr_result: nil)
    Receipts::Processing::Contracts::FinalizeDecision.new(
      finalize_strategy: strategy.to_s,
      error_code: error_code,
      error_message: error_code,
      receipt_attributes: {},
      ocr_result:,
      ai_result: nil,
      metadata: {}
    )
  end

  def ai_result
    {
      success: true,
      needs_review: false,
      review_reasons: [],
      receipt_attributes: {},
      receipt_items_attributes: []
    }
  end

  def build_ready_run(receipt, fixture: nil, ocr_result: nil, normalized_ai_result: nil, strategy:, source: 'upload', parent_run: nil)
    run = Receipts::Processing.start(receipt: receipt, source: source, parent_run: parent_run).run
    Receipts::Processing.record_ocr_snapshot(run, ocr_result || ocr_fixture(fixture))
    Receipts::Processing.record_ai_normalized_result(run, normalized_ai_result || ai_result) if strategy == :ai_success
    Receipts::Processing.record_finalize_decision(
      run,
      finalize_decision(strategy, error_code: strategy == :ai_fallback ? 'ai_unavailable' : nil)
    )
    run.reload
  end

  def structured_reference_without_total_ocr_result
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_item_calculation_reference_gross_anonymized.json').read
    )
    analyze_result = raw.fetch('analyzeResult')
    document = analyze_result.fetch('documents').sole
    item = document.dig('fields', 'Items', 'valueArray').sole
    content = "検証品\n税込 ¥498/100g\n342g"
    analyze_result['content'] = content
    analyze_result.fetch('pages').sole.fetch('lines').pop
    analyze_result.fetch('pages').sole.fetch('spans').sole['length'] = content.length
    document.fetch('spans').sole['length'] = content.length
    item['content'] = content
    item.fetch('spans').sole['length'] = content.length
    item.fetch('valueObject').delete('TotalPrice')

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def mixed_structured_reference_count_ocr_result
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_item_calculation_reference_gross_anonymized.json').read
    )
    analyze_result = raw.fetch('analyzeResult')
    document = analyze_result.fetch('documents').sole
    second_item_content = "確認品\n¥220 x 2個\n¥440"
    second_item_start = analyze_result.fetch('content').length + 1
    analyze_result['content'] = "#{analyze_result.fetch('content')}\n#{second_item_content}"
    analyze_result.fetch('pages').sole.fetch('lines').concat(
      [
        {
          'content' => '確認品',
          'polygon' => [ 100, 240, 300, 240, 300, 270, 100, 270 ],
          'spans' => [ { 'offset' => second_item_start, 'length' => 3 } ]
        },
        {
          'content' => '¥220 x 2個',
          'polygon' => [ 100, 280, 500, 280, 500, 310, 100, 310 ],
          'spans' => [ { 'offset' => second_item_start + 4, 'length' => 9 } ]
        },
        {
          'content' => '¥440',
          'polygon' => [ 700, 240, 900, 240, 900, 270, 700, 270 ],
          'spans' => [ { 'offset' => second_item_start + 14, 'length' => 4 } ]
        }
      ]
    )
    analyze_result.fetch('pages').sole.fetch('spans').sole['length'] = analyze_result.fetch('content').length
    document.fetch('spans').sole['length'] = analyze_result.fetch('content').length
    document.dig('fields', 'Items', 'valueArray') << {
      'type' => 'object',
      'content' => second_item_content,
      'spans' => [ { 'offset' => second_item_start, 'length' => second_item_content.length } ],
      'valueObject' => {
        'Description' => {
          'type' => 'string',
          'valueString' => '確認品',
          'content' => '確認品',
          'spans' => [ { 'offset' => second_item_start, 'length' => 3 } ]
        },
        'Price' => {
          'type' => 'currency',
          'valueCurrency' => { 'currencySymbol' => '¥', 'amount' => 220, 'currencyCode' => 'JPY' },
          'content' => '¥220',
          'spans' => [ { 'offset' => second_item_start + 4, 'length' => 4 } ]
        },
        'Quantity' => {
          'type' => 'number',
          'valueNumber' => 2,
          'content' => '2',
          'spans' => [ { 'offset' => second_item_start + 11, 'length' => 1 } ]
        },
        'QuantityUnit' => {
          'type' => 'string',
          'valueString' => '個',
          'content' => '個',
          'spans' => [ { 'offset' => second_item_start + 12, 'length' => 1 } ]
        },
        'TotalPrice' => {
          'type' => 'currency',
          'valueCurrency' => { 'currencySymbol' => '¥', 'amount' => 440, 'currencyCode' => 'JPY' },
          'content' => '¥440',
          'spans' => [ { 'offset' => second_item_start + 14, 'length' => 4 } ]
        }
      }
    }

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def item_layout_ocr_result
    candidate_prefix = 'azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l4'
    item_identity = 'azure_item_layout_item_p0_name_l1_s16_e22_ref_l2_qty_l3_total_l4'
    evidence = lambda do |line_index, span_start, span_end|
      {
        source_provider: 'azure_item_layout',
        source_field_path: "pages[0].lines[#{line_index}]",
        page_index: 0,
        line_index: line_index,
        string_index_type: 'textElements',
        provider_span_start: span_start,
        provider_span_end: span_end
      }
    end

    {
      success: true,
      lines: [ '架空店', '例示品', '税込 498円/100g', '計量 342g', '1,703円', '合計 1,703円' ],
      case_preserved_lines: [ '架空店', '例示品', '税込 498円/100g', '計量 342g', '1,703円', '合計 1,703円' ],
      candidates: {
        total_amount: 1703,
        reference_pricing_block_line_indexes: [ 1, 2, 3, 4 ],
        items: [
          {
            raw_text: '例示品',
            price: '498',
            quantity: '342',
            quantity_unit_code: 'gram',
            quantity_unit_status: 'known',
            line_total: 1703,
            original_line_total: 1703,
            ocr_item_identity: item_identity
          }
        ],
        reference_pricing_candidates: [
          {
            candidate_id: "#{candidate_prefix}_reference_pricing",
            source_kind: 'azure_item_layout',
            item_index: 0,
            item_identity: item_identity,
            destination_kind: 'azure_layout_item',
            page_index: 0,
            name_line_index: 1,
            reference_line_index: 2,
            purchased_quantity_line_indexes: [ 3 ],
            printed_total_line_index: 4,
            owned_line_indexes: [ 1, 2, 3, 4 ],
            provider_model_id: 'prebuilt-receipt',
            provider_api_version: '2024-11-30',
            string_index_type: 'textElements',
            validation_contract_version: 'azure_item_layout_v1',
            block_provider_span_start: 16,
            block_provider_span_end: 66,
            validation_state: 'valid',
            rejection_reasons: [],
            reference_price: { amount: '498', evidence: evidence.call(2, 29, 32) },
            reference_quantity: {
              amount: '100',
              unit_code: 'gram',
              unit_status: 'known',
              origin: 'explicit',
              evidence: evidence.call(2, 34, 38)
            },
            purchased_quantity: {
              amount: '342',
              unit_code: 'gram',
              unit_status: 'known',
              evidence: evidence.call(3, 43, 47)
            },
            reference_price_tax_inclusion: 'gross',
            tax_inclusion_evidence: evidence.call(2, 26, 28),
            printed_line_total: { amount: '1703', evidence: evidence.call(4, 49, 55) },
            corroboration: {
              exact_amount: { numerator: '42579', denominator: '25' },
              projected_amount: 1703,
              printed_line_total: '1703',
              rounding_matches: %w[floor half_up]
            }
          }
        ],
        item_calculation_mode_candidates: [
          {
            candidate_id: "#{candidate_prefix}_item_calculation_mode",
            item_identity: item_identity,
            item_index: 0,
            source_provider: 'azure_item_layout',
            provider_model_id: 'prebuilt-receipt',
            provider_api_version: '2024-11-30',
            string_index_type: 'textElements',
            source_field_path: 'pages[0].lines[1]',
            provider_span_start: 16,
            provider_span_end: 66,
            destination_evidence: evidence.call(1, 16, 22),
            destination_kind: 'azure_layout_item',
            printed_line_total: {
              amount: '1703',
              evidence: evidence.call(4, 49, 55)
            },
            conflicts: [],
            options: [
              {
                proposal_id: "#{candidate_prefix}_explicit_line_total",
                pricing_source_kind: 'explicit_line_total',
                source: { line_total_amount: '1703' },
                evidence: { line_total: evidence.call(4, 49, 55) }
              }
            ]
          }
        ],
        payments: [],
        tax_details: [],
        adjustment_candidates: [],
        review_reasons: []
      },
      meta: {
        provider: 'azure_document_intelligence',
        model_id: 'prebuilt-receipt'
      }
    }
  end

  def count_total_mismatch_ocr_result
    raw = JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)
    analyze_result = raw.fetch('analyzeResult')
    analyze_result.dig('documents', 0, 'fields', 'Items', 'valueArray').each do |item|
      total = item.dig('valueObject', 'TotalPrice')
      amount = total.dig('valueCurrency', 'amount') + 1
      content = "¥#{amount}"
      raise 'replacement must preserve fixture span length' unless content.length == total.fetch('content').length

      span = total.fetch('spans').sole
      parent_offset = item.fetch('spans').sole.fetch('offset')
      analyze_result.fetch('content')[span.fetch('offset'), span.fetch('length')] = content
      item.fetch('content')[span.fetch('offset') - parent_offset, span.fetch('length')] = content
      total['content'] = content
      total.fetch('valueCurrency')['amount'] = amount
    end

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def create_reference_pricing_setting(value)
    create(
      :system_setting,
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      value: SystemSettings.stored_value(value)
    )
  end

  it 'OCR-onlyでconfirmed count sourceを現在金額を変えず保存し、statusは従来どおりreview_neededにする' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ocr_only)

    result = Receipts::Processing.run_finalize(run)

    aggregate_failures do
      expect(result.next_step).to eq(:done)
      expect(receipt.reload).to have_attributes(
        status: 'review_needed',
        subtotal_amount: 700,
        tax_amount: 70,
        total_amount: 770
      )
      expect(receipt.receipt_items.order(:position_index)).to all(
        have_attributes(
          pricing_source_kind: 'count_unit_price',
          quantity: BigDecimal('1'),
          quantity_unit_code: 'item'
        )
      )
      expect(receipt.receipt_items.order(:position_index).pluck(:price, :original_line_total, :line_total)).to eq(
        [ 220, 132, 110, 308 ].map { |amount| [ amount, amount, amount ] }
      )
      expect(receipt.review_reasons).not_to include('item_pricing_mode_uncertain')
      expect(receipt.receipt_items).to all(
        satisfy { |item| !Array(item.review_reasons).include?('item_pricing_mode_uncertain') }
      )
      expect(receipt.amount_calculation_profile.dig('profile', 'receipt_tax_basis')).to eq('total_includes_tax')
      expect(run.reload).to have_attributes(status: 'succeeded', stage: 'completed')
    end
  end

  it 'AI successも同じtyped OCR sourceからcount authorityを保存する' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ai_success)

    Receipts::Processing.run_finalize(run)

    aggregate_failures do
      expect(receipt.reload.total_amount).to eq(770)
      expect(receipt.receipt_items.order(:position_index).pluck(:pricing_source_kind).uniq).to eq(
        [ 'count_unit_price' ]
      )
      expect(run.reload.status).to eq('succeeded')
    end
  end

  it 'AIの0始まりitem indexを保存先positionに使っても先頭Itemのcount authorityを保存する' do
    ocr_result = ocr_fixture('single_tax_receipt')
    normalized_ai_result = ai_result.merge(
      receipt_items_attributes: Array(ocr_result.dig(:candidates, :items)).each_with_index.map do |_item, index|
        {
          index: index,
          suggested_name: "AI商品#{index + 1}",
          category: 'other',
          needs_review: false
        }
      end
    )
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(
      receipt,
      ocr_result:,
      normalized_ai_result:,
      strategy: :ai_success
    )

    Receipts::Processing.run_finalize(run)

    items = receipt.reload.receipt_items.order(:position_index)
    aggregate_failures do
      expect(items.pluck(:position_index)).to eq([ 0, 1, 2, 3 ])
      expect(items.pluck(:pricing_source_kind).uniq).to eq([ 'count_unit_price' ])
      expect(items.first).to have_attributes(
        suggested_name: 'AI商品1',
        price: 220,
        original_line_total: 220,
        line_total: 220
      )
      expect(run.reload.status).to eq('succeeded')
    end
  end

  it 'formulaとstrong printed totalの不一致はexplicitをprefillし、該当Itemだけ計算方式reviewにする' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(
      receipt,
      ocr_result: count_total_mismatch_ocr_result,
      strategy: :ai_success
    )

    Receipts::Processing.run_finalize(run)

    items = receipt.reload.receipt_items.order(:position_index)
    aggregate_failures do
      expect(receipt).to have_attributes(status: 'review_needed', total_amount: 770)
      expect(receipt.review_reasons).to include('item_pricing_mode_uncertain')
      expect(items.pluck(:pricing_source_kind)).to all(eq('explicit_line_total'))
      expect(items.pluck(:original_line_total, :line_total)).to eq(
        [ 221, 133, 111, 309 ].map { |amount| [ amount, amount ] }
      )
      expect(items).to all(
        have_attributes(
          needs_review: true,
          review_reasons: include('item_pricing_mode_uncertain')
        )
      )
      expect(run.reload.status).to eq('succeeded')
    end
  end

  it 'AI fallbackでstrong printed totalをexplicit authorityとして0円明細も欠損させない' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'receipt_sample', strategy: :ai_fallback)

    Receipts::Processing.run_finalize(run)

    items = receipt.reload.receipt_items.order(:position_index)
    aggregate_failures do
      expect(receipt).to have_attributes(status: 'review_needed', total_amount: 1130)
      expect(items.pluck(:pricing_source_kind).uniq).to eq([ 'explicit_line_total' ])
      expect(items.pluck(:price)).to all(be_nil)
      expect(items.pluck(:original_line_total, :line_total)).to eq(
        [ 580, 200, 250, 100, 0 ].map { |amount| [ amount, amount ] }
      )
      expect(run.reload.status).to eq('succeeded')
    end
  end

  it 'Azure item-layout proposalをsnapshotから復元して同じ明細へexplicit authorityとして保存する' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(
      receipt,
      ocr_result: item_layout_ocr_result,
      strategy: :ocr_only
    )
    snapshot_before = run.ocr_result_snapshot.deep_dup

    result = Receipts::Processing.run_finalize(run)

    item = receipt.reload.receipt_items.sole
    aggregate_failures do
      expect(snapshot_before.dig('adoption_proposals', 'reference_pricing')).to be_nil
      expect(snapshot_before.dig('adoption_proposals', 'item_calculation_modes').sole.fetch('options')).to contain_exactly(
        include('pricing_source_kind' => 'explicit_line_total')
      )
      expect(result.next_step).to eq(:done)
      expect(receipt).to have_attributes(status: 'review_needed', total_amount: 1703)
      expect(item).to have_attributes(
        pricing_source_kind: 'explicit_line_total',
        price: nil,
        quantity: BigDecimal('342'),
        quantity_unit_code: 'gram',
        reference_price_amount: nil,
        reference_quantity: nil,
        reference_quantity_unit_code: nil,
        reference_quantity_unit_raw: nil,
        reference_price_tax_inclusion: nil,
        original_line_total: 1703,
        line_total: 1703
      )
      expect(run.reload).to have_attributes(status: 'succeeded', stage: 'completed')
      expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
      expect(run.ocr_result_snapshot).to eq(snapshot_before)
    end
  end

  it 'SystemSetting有効時だけconfirmed structured referenceを同じItemへexact sourceとして保存する' do
    create_reference_pricing_setting(true)
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(
      receipt,
      fixture: 'ocr_azure_item_calculation_reference_gross_anonymized',
      strategy: :ocr_only
    )
    proposal_before = run.ocr_result_snapshot.dig('adoption_proposals', 'item_calculation_modes').deep_dup

    result = Receipts::Processing.run_finalize(run)

    item = receipt.reload.receipt_items.sole
    aggregate_failures do
      expect(result.next_step).to eq(:done)
      expect(receipt).to have_attributes(status: 'review_needed', total_amount: 1703)
      expect(item).to have_attributes(
        pricing_source_kind: 'reference_quantity_price',
        price: nil,
        reference_price_amount: BigDecimal('498'),
        reference_quantity: BigDecimal('100'),
        reference_quantity_unit_code: 'gram',
        reference_price_tax_inclusion: 'gross',
        quantity: BigDecimal('342'),
        quantity_unit_code: 'gram',
        original_line_total: 1703,
        line_total: 1703
      )
      expect(run.reload.metadata.dig('reference_pricing_auto_adoption_claim', 'proposal_checksum')).to be_present
      expect(run.ocr_result_snapshot.dig('adoption_proposals', 'item_calculation_modes')).to eq(proposal_before)
    end
  end

  it 'SystemSetting有効時に単一明細summary gross proposalを既存Amount経由でreference authorityへ保存する' do
    create_reference_pricing_setting(true)
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(
      receipt,
      fixture: 'ocr_azure_item_calculation_reference_summary_gross_anonymized',
      strategy: :ocr_only
    )
    proposal_before = run.ocr_result_snapshot.dig('adoption_proposals', 'item_calculation_modes').sole
    reference_option = proposal_before.fetch('options').find do |option|
      option['pricing_source_kind'] == 'reference_quantity_price'
    end

    result = Receipts::Processing.run_finalize(run)

    item = receipt.reload.receipt_items.sole
    aggregate_failures do
      expect(result.next_step).to eq(:done)
      expect(receipt).to have_attributes(status: 'review_needed', total_amount: 1703, tax_amount: 154)
      expect(proposal_before).to include(
        'candidate_id' => start_with('azure_item_layout_'),
        'item_identity' => start_with('azure_structured_item_')
      )
      expect(reference_option).to include(
        'proposal_id' => start_with('azure_item_layout_'),
        'pricing_source_kind' => 'reference_quantity_price',
        'source' => include(
          'reference_price_amount' => '498',
          'reference_quantity' => '100',
          'reference_quantity_unit_code' => 'gram',
          'purchased_quantity' => '342',
          'purchased_quantity_unit_code' => 'gram',
          'reference_price_tax_inclusion' => 'gross'
        )
      )
      expect(item).to have_attributes(
        pricing_source_kind: 'reference_quantity_price',
        price: nil,
        reference_price_amount: BigDecimal('498'),
        reference_quantity: BigDecimal('100'),
        reference_quantity_unit_code: 'gram',
        reference_price_tax_inclusion: 'gross',
        quantity: BigDecimal('342'),
        quantity_unit_code: 'gram',
        original_line_total: 1703,
        line_total: 1703
      )
      expect(run.reload.metadata.dig('reference_pricing_auto_adoption_claim', 'proposal_checksum')).to eq(
        proposal_before.fetch('integrity_checksum')
      )
      expect(run.ocr_result_snapshot.dig('adoption_proposals', 'item_calculation_modes').sole).to eq(
        proposal_before
      )
    end
  end

  it 'SystemSetting無効時も単一明細summary gross proposalと印字額を維持しauthorityへ昇格しない' do
    create_reference_pricing_setting(false)
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(
      receipt,
      fixture: 'ocr_azure_item_calculation_reference_summary_gross_anonymized',
      strategy: :ocr_only
    )
    proposal_before = run.ocr_result_snapshot.dig('adoption_proposals', 'item_calculation_modes').sole

    Receipts::Processing.run_finalize(run)

    item = receipt.reload.receipt_items.sole
    aggregate_failures do
      expect(receipt).to have_attributes(status: 'review_needed', total_amount: 1703, tax_amount: 154)
      expect(item).to have_attributes(
        pricing_source_kind: nil,
        reference_price_amount: nil,
        reference_quantity: nil,
        reference_quantity_unit_code: nil,
        reference_price_tax_inclusion: nil,
        original_line_total: 1703,
        line_total: 1703
      )
      expect(proposal_before.fetch('options').map { |option| option['pricing_source_kind'] }).to contain_exactly(
        'reference_quantity_price',
        'explicit_line_total'
      )
      expect(run.reload.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
      expect(run.ocr_result_snapshot.dig('adoption_proposals', 'item_calculation_modes').sole).to eq(
        proposal_before
      )
    end
  end

  it 'SystemSetting無効時もstructured proposalと印字額を維持するがreference authorityは作らない' do
    create_reference_pricing_setting(false)
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(
      receipt,
      fixture: 'ocr_azure_item_calculation_reference_gross_anonymized',
      strategy: :ocr_only
    )

    Receipts::Processing.run_finalize(run)

    item = receipt.reload.receipt_items.sole
    aggregate_failures do
      expect(receipt.total_amount).to eq(1703)
      expect(item).to have_attributes(
        pricing_source_kind: nil,
        reference_price_amount: nil,
        reference_quantity: nil,
        reference_quantity_unit_code: nil,
        reference_price_tax_inclusion: nil,
        original_line_total: 1703,
        line_total: 1703
      )
      expect(run.reload.ocr_result_snapshot.dig('adoption_proposals', 'item_calculation_modes')).to be_present
      expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
    end
  end

  it 'structured referenceのrun開始後にSystemSetting世代が変われば再度ONでも採用しない' do
    setting = create_reference_pricing_setting(true)
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(
      receipt,
      fixture: 'ocr_azure_item_calculation_reference_gross_anonymized',
      strategy: :ocr_only
    )
    setting.update!(value: SystemSettings.stored_value(false))
    setting.update!(value: SystemSettings.stored_value(true))

    Receipts::Processing.run_finalize(run)

    item = receipt.reload.receipt_items.sole
    aggregate_failures do
      expect(receipt.total_amount).to eq(1703)
      expect(item).to have_attributes(
        pricing_source_kind: nil,
        reference_price_amount: nil,
        reference_quantity: nil,
        reference_quantity_unit_code: nil,
        reference_price_tax_inclusion: nil,
        original_line_total: 1703,
        line_total: 1703
      )
      expect(run.reload.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
    end
  end

  it '印字明細額なしでもcompleteなgross structured formulaだけを既存Amountで投影して保存する' do
    create_reference_pricing_setting(true)
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(
      receipt,
      ocr_result: structured_reference_without_total_ocr_result,
      strategy: :ocr_only
    )

    Receipts::Processing.run_finalize(run)

    item = receipt.reload.receipt_items.sole
    aggregate_failures do
      expect(receipt.total_amount).to eq(1703)
      expect(item).to have_attributes(
        pricing_source_kind: 'reference_quantity_price',
        reference_price_amount: BigDecimal('498'),
        reference_quantity: BigDecimal('100'),
        reference_quantity_unit_code: 'gram',
        reference_price_tax_inclusion: 'gross',
        quantity: BigDecimal('342'),
        quantity_unit_code: 'gram',
        original_line_total: 1703,
        line_total: 1703
      )
      expect(run.reload.metadata.dig('reference_pricing_auto_adoption_claim', 'proposal_checksum')).to be_present
    end
  end

  it 'structured reference 1件とconfirmed countが混在しても同じAmount transactionで両方式を保存する' do
    create_reference_pricing_setting(true)
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(
      receipt,
      ocr_result: mixed_structured_reference_count_ocr_result,
      strategy: :ocr_only
    )

    Receipts::Processing.run_finalize(run)

    reference_item, count_item = receipt.reload.receipt_items.order(:position_index)
    aggregate_failures do
      expect(receipt.total_amount).to eq(2143)
      expect(reference_item).to have_attributes(
        pricing_source_kind: 'reference_quantity_price',
        reference_price_amount: BigDecimal('498'),
        reference_quantity: BigDecimal('100'),
        reference_quantity_unit_code: 'gram',
        quantity: BigDecimal('342'),
        quantity_unit_code: 'gram',
        line_total: 1703
      )
      expect(count_item).to have_attributes(
        pricing_source_kind: 'count_unit_price',
        price: 220,
        quantity: BigDecimal('2'),
        quantity_unit_code: 'each',
        line_total: 440
      )
      expect(run.reload.metadata.dig('reference_pricing_auto_adoption_claim', 'proposal_checksum')).to be_present
    end
  end

  it '親runを持つ再解析ではstable item lineageなしに新しいauthorityを上書きしない' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    parent_run = create(:receipt_analysis_run, :succeeded, receipt: receipt)
    run = build_ready_run(
      receipt,
      fixture: 'single_tax_receipt',
      strategy: :ocr_only,
      source: 'admin_retry',
      parent_run: parent_run
    )

    Receipts::Processing.run_finalize(run)

    aggregate_failures do
      expect(receipt.reload.receipt_items).to all(have_attributes(pricing_source_kind: nil))
      expect(receipt.total_amount).to eq(770)
    end
  end

  it 'inline OCR結果を優先するdirect finalizeへ保存済みsnapshotのauthorityを混在させない' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ocr_only)
    inline_ocr_result = ocr_fixture('single_tax_receipt')

    Receipts::Processing::Pipeline::FinalizeStep.call(
      receipt:,
      decision: finalize_decision(:ocr_only, ocr_result: inline_ocr_result),
      run:
    )

    aggregate_failures do
      expect(receipt.reload.total_amount).to eq(770)
      expect(receipt.receipt_items).to all(have_attributes(pricing_source_kind: nil))
    end
  end

  it 'Amount失敗時も従来どおりbounded BuildParams snapshotを先に記録する' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ocr_only)
    allow(ReceiptAmountService).to receive(:call).and_raise('amount failed')

    expect do
      Receipts::Processing::Pipeline::FinalizeStep.call(
        receipt:,
        decision: finalize_decision(:ocr_only),
        run:
      )
    end.to raise_error('amount failed')

    aggregate_failures do
      expect(run.reload.metadata['build_params_snapshot']).to be_present
      expect(receipt.reload.status).to eq('processing')
      expect(receipt.receipt_items).to be_empty
    end
  end

  it '同じrunのfinalize再実行では明細を重複作成しない' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ocr_only)

    first_result = Receipts::Processing.run_finalize(run)
    item_ids = receipt.reload.receipt_items.order(:position_index).ids
    second_result = Receipts::Processing.run_finalize(run.reload)

    aggregate_failures do
      expect(first_result.next_step).to eq(:done)
      expect(second_result).to have_attributes(next_step: :skipped, skip_reason: :terminal_run)
      expect(receipt.reload.receipt_items.order(:position_index).ids).to eq(item_ids)
      expect(receipt.receipt_items).to all(have_attributes(pricing_source_kind: 'count_unit_price'))
    end
  end

  it 'final result保存失敗時は計算方式authorityと明細を同じtransactionでrollbackする' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ocr_only)
    original_total = receipt.total_amount
    allow(Receipts::Processing).to receive(:record_final_result).and_raise('summary write failed')

    expect { Receipts::Processing.run_finalize(run) }.to raise_error('summary write failed')

    aggregate_failures do
      expect(receipt.reload.receipt_items).to be_empty
      expect(receipt.total_amount).to eq(original_total)
      expect(receipt.status).to eq('failed')
      expect(run.reload.status).to eq('failed')
      expect(run.final_result_summary).to be_blank
    end
  end

  it 'structured referenceのfinal result保存失敗時もauthority・claim・明細を一体でrollbackする' do
    create_reference_pricing_setting(true)
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(
      receipt,
      fixture: 'ocr_azure_item_calculation_reference_gross_anonymized',
      strategy: :ocr_only
    )
    original_total = receipt.total_amount
    allow(Receipts::Processing).to receive(:record_final_result).and_raise('summary write failed')

    expect { Receipts::Processing.run_finalize(run) }.to raise_error('summary write failed')

    aggregate_failures do
      expect(receipt.reload.receipt_items).to be_empty
      expect(receipt).to have_attributes(status: 'failed', total_amount: original_total)
      expect(run.reload).to have_attributes(status: 'failed')
      expect(run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
      expect(run.metadata.dig('stage_execution_claims', 'finalize')).to be_nil
      expect(run.final_result_summary).to be_blank
    end
  end

  it '永続化時のtrusted source driftはFinalizeStep単体でも全明細をrollbackする' do
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = build_ready_run(receipt, fixture: 'single_tax_receipt', strategy: :ocr_only)
    original_total = receipt.total_amount
    trusted_normalizations = 0
    normalizer = Receipts::Processing::Pipeline::FinalizeStep::AttributeNormalizer
    allow(normalizer).to receive(:items).and_wrap_original do |original, items, **options|
      original.call(items, **options).tap do |normalized|
        next if Array(options[:trusted_item_calculation_mode_sources]).empty?

        trusted_normalizations += 1
        normalized.each { |item| item.delete(:pricing_source_kind) } if trusted_normalizations == 2
      end
    end

    expect do
      Receipts::Processing::Pipeline::FinalizeStep.call(
        receipt:,
        decision: finalize_decision(:ocr_only),
        run:
      )
    end.to raise_error(
      Receipts::Processing::AnalysisError,
      'item_calculation_mode_persistence_mismatch'
    )

    aggregate_failures do
      expect(trusted_normalizations).to eq(2)
      expect(receipt.reload).to have_attributes(status: 'processing', total_amount: original_total)
      expect(receipt.receipt_items).to be_empty
    end
  end
end
