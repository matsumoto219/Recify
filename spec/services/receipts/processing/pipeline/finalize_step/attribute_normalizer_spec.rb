require 'rails_helper'

RSpec.describe Receipts::Processing::Pipeline::FinalizeStep::AttributeNormalizer do
  def count_selection(
    identity: 'azure_structured_item_i0_s100_e115',
    item_index: 0,
    position_index: 1,
    proposal_id: nil,
    price: 120,
    quantity: BigDecimal('2'),
    unit: 'item',
    projected_line_total: 240,
    review_reason: nil
  )
    Receipts::Processing::Pipeline::FinalizeStep::ItemCalculationModeApplicator::Selection.new(
      item_identity: identity,
      item_index: item_index,
      position_index: position_index,
      proposal_id: proposal_id || "azure_items_#{item_index}_count_unit_price",
      pricing_source_kind: 'count_unit_price',
      price: price,
      quantity: quantity,
      quantity_unit_code: unit,
      projected_line_total: projected_line_total,
      review_reason:
    )
  end

  def explicit_selection(
    identity: 'azure_structured_item_i0_s100_e115',
    item_index: 0,
    position_index: 1,
    proposal_id: nil,
    line_total: 240,
    review_reason: nil
  )
    Receipts::Processing::Pipeline::FinalizeStep::ItemCalculationModeApplicator::Selection.new(
      item_identity: identity,
      item_index: item_index,
      position_index: position_index,
      proposal_id: proposal_id || "azure_items_#{item_index}_explicit_line_total",
      pricing_source_kind: 'explicit_line_total',
      explicit_line_total: line_total,
      projected_line_total: line_total,
      review_reason:
    )
  end

  def reference_selection(
    identity: 'azure_structured_item_i0_s100_e115',
    item_index: 0,
    position_index: 1,
    proposal_id: nil,
    reference_price: BigDecimal('498'),
    reference_quantity: BigDecimal('100'),
    reference_unit: 'gram',
    quantity: BigDecimal('342'),
    quantity_unit: 'gram',
    tax_inclusion: 'gross',
    price: nil,
    explicit_line_total: nil,
    projected_line_total: 1703
  )
    Receipts::Processing::Pipeline::FinalizeStep::ItemCalculationModeApplicator::Selection.new(
      item_identity: identity,
      item_index: item_index,
      position_index: position_index,
      proposal_id: proposal_id || "azure_items_#{item_index}_reference_quantity_price",
      pricing_source_kind: 'reference_quantity_price',
      price: price,
      quantity: quantity,
      quantity_unit_code: quantity_unit,
      reference_price_amount: reference_price,
      reference_quantity: reference_quantity,
      reference_quantity_unit_code: reference_unit,
      reference_price_tax_inclusion: tax_inclusion,
      explicit_line_total: explicit_line_total,
      projected_line_total: projected_line_total
    )
  end

  def reference_source(selection = reference_selection, **overrides)
    {
      raw_text: '検証明細',
      ocr_item_identity: selection.item_identity,
      pricing_source_kind: 'reference_quantity_price',
      price: nil,
      quantity: selection.quantity,
      quantity_unit_code: selection.quantity_unit_code,
      quantity_unit_raw: nil,
      reference_price_amount: selection.reference_price_amount,
      reference_quantity: selection.reference_quantity,
      reference_quantity_unit_code: selection.reference_quantity_unit_code,
      reference_quantity_unit_raw: nil,
      reference_price_tax_inclusion: selection.reference_price_tax_inclusion,
      original_line_total: selection.projected_line_total,
      line_total: selection.projected_line_total,
      discount_amount: nil,
      discount_rate: nil,
      position_index: selection.position_index
    }.merge(overrides)
  end

  def trusted_items(items, selections)
    described_class.items(
      items,
      trusted_item_calculation_mode_sources: selections,
      item_price_limit: 999_999_999,
      item_line_total_limit: 999_999_999
    )
  end

  describe '.items' do
    it 'normalizes receipt item attributes without changing names or the input' do
      item = {
        'raw_text' => ' OCR Raw ',
        'suggested_name' => '提案名',
        'confirmed_name' => '確定名',
        'category' => 'food',
        'price' => '1200',
        'quantity' => '2.5',
        'quantity_unit_code' => 'kg',
        'product_code' => 'P001',
        'tax_rate' => '8%',
        'original_line_total' => '3000',
        'line_total' => '2800',
        'discount_amount' => '200',
        'discount_rate' => '10%',
        'needs_review' => false,
        'review_reasons' => [ ' item_name_uncertain ', '', 'item_name_uncertain' ],
        'position_index' => 7,
        'confidence' => '0.75'
      }
      original = item.deep_dup

      result = described_class.items([ item ]).first

      expect(result).to eq(
        raw_text: ' OCR Raw ',
        suggested_name: '提案名',
        confirmed_name: '確定名',
        category: 'food',
        price: BigDecimal('1200'),
        quantity: BigDecimal('2.5'),
        quantity_unit_code: 'kilogram',
        product_code: 'P001',
        tax_rate: BigDecimal('0.08'),
        original_line_total: BigDecimal('3000'),
        line_total: BigDecimal('2800'),
        discount_amount: BigDecimal('200'),
        discount_rate: BigDecimal('0.1'),
        needs_review: false,
        review_reasons: [ 'item_name_uncertain' ],
        position_index: 7,
        confidence: BigDecimal('0.75')
      )
      expect(item).to eq(original)
    end

    it 'typed proposalのOCR identityをtrusted applicator接続前のReceiptItem属性へ通さない' do
      result = described_class.items(
        [
          {
            raw_text: '検証明細',
            line_total: 200,
            ocr_item_identity: 'azure_structured_item_i0_s100_e115'
          }
        ]
      ).sole

      expect(result).not_to have_key(:ocr_item_identity)
    end

    it 'rejects an item with any negative amount but keeps a zero-yen item' do
      result = described_class.items(
        [
          { raw_text: 'negative', line_total: -1 },
          { raw_text: 'zero', price: 0, line_total: 0 }
        ]
      )

      expect(result).to contain_exactly(include(raw_text: 'zero', price: 0, line_total: 0))
    end

    it 'defaults blank, zero, and negative quantities to one' do
      result = described_class.items(
        [
          { raw_text: 'blank', quantity: '' },
          { raw_text: 'zero', quantity: 0 },
          { raw_text: 'negative', quantity: -2 }
        ]
      )

      expect(result.map { |item| item[:quantity] }).to all(eq(BigDecimal('1')))
    end

    it 'A1で検証済みのexact sourceだけをfractional値を変えずに保持する' do
      source = {
        raw_text: '検証明細',
        price: nil,
        quantity: BigDecimal('2.5'),
        quantity_unit_code: 'liter',
        quantity_unit_raw: nil,
        pricing_source_kind: 'reference_quantity_price',
        reference_price_amount: '1.25',
        reference_quantity: '0.5',
        reference_quantity_unit_code: 'liter',
        reference_quantity_unit_raw: nil,
        reference_price_tax_inclusion: 'gross'
      }

      trusted = described_class.items(
        [ source ],
        trusted_reference_pricing_auto_adoption: true
      ).sole
      untrusted = described_class.items([ source ]).sole

      aggregate_failures do
        expect(trusted).to include(
          price: nil,
          quantity: BigDecimal('2.5'),
          pricing_source_kind: 'reference_quantity_price',
          reference_price_amount: BigDecimal('1.25'),
          reference_quantity: BigDecimal('0.5'),
          reference_quantity_unit_code: 'liter',
          reference_price_tax_inclusion: 'gross'
        )
        expect(untrusted).not_to have_key(:pricing_source_kind)
        expect(untrusted).not_to have_key(:reference_price_amount)
      end
    end

    it 'trusted指定でもscientific・Float・alias unit・partial sourceをdefault補完しない' do
      valid = {
        raw_text: '検証明細',
        quantity: '2.5',
        quantity_unit_code: 'liter',
        quantity_unit_raw: nil,
        pricing_source_kind: 'reference_quantity_price',
        reference_price_amount: '120',
        reference_quantity: '1',
        reference_quantity_unit_code: 'liter',
        reference_quantity_unit_raw: nil,
        reference_price_tax_inclusion: 'gross'
      }
      invalid = [
        valid.merge(reference_price_amount: '1e2'),
        valid.merge(reference_price_amount: 120.0),
        valid.merge(quantity_unit_code: 'L'),
        valid.merge(reference_quantity: nil),
        valid.merge(reference_quantity_unit_raw: 'L')
      ]

      invalid.each do |source|
        expect(
          described_class.items(
            [ source ],
            trusted_reference_pricing_auto_adoption: true
          )
        ).to be_empty
      end
    end

    it 'item identityとexact sourceが一致するcount authorityだけを保持する' do
      source = {
        raw_text: '検証明細',
        ocr_item_identity: 'azure_structured_item_i0_s100_e115',
        pricing_source_kind: 'count_unit_price',
        price: 120,
        quantity: BigDecimal('2'),
        quantity_unit_code: 'item',
        quantity_unit_raw: nil,
        original_line_total: 240,
        line_total: 240,
        discount_amount: nil,
        discount_rate: nil,
        position_index: 1
      }

      result = trusted_items([ source ], [ count_selection ]).sole

      aggregate_failures do
        expect(result).to include(
          pricing_source_kind: 'count_unit_price',
          price: BigDecimal('120'),
          quantity: BigDecimal('2'),
          quantity_unit_code: 'item',
          original_line_total: BigDecimal('240'),
          line_total: BigDecimal('240')
        )
        expect(result).not_to have_key(:ocr_item_identity)
        expect(result[:reference_price_amount]).to be_nil
      end
    end

    it 'Fence後のexact structured reference sourceだけをfractional値を変えず保持する' do
      selection = reference_selection(
        reference_price: BigDecimal('1.25'),
        reference_quantity: BigDecimal('0.5'),
        reference_unit: 'liter',
        quantity: BigDecimal('2.5'),
        quantity_unit: 'liter',
        projected_line_total: 6
      )

      result = trusted_items([ reference_source(selection) ], [ selection ]).sole

      expect(result).to include(
        pricing_source_kind: 'reference_quantity_price',
        price: nil,
        reference_price_amount: BigDecimal('1.25'),
        reference_quantity: BigDecimal('0.5'),
        reference_quantity_unit_code: 'liter',
        reference_price_tax_inclusion: 'gross',
        quantity: BigDecimal('2.5'),
        quantity_unit_code: 'liter',
        original_line_total: BigDecimal('6'),
        line_total: BigDecimal('6')
      )
    end

    it 'structured referenceの余分なsource・raw unit・net・unit不一致・数値境界違反をauthorityにしない' do
      cases = []
      cases << [ reference_selection(price: 498), reference_source ]
      cases << [ reference_selection(explicit_line_total: 1703), reference_source ]
      cases << [ reference_selection, reference_source(quantity_unit_raw: 'g') ]

      net_selection = reference_selection(tax_inclusion: 'net')
      cases << [ net_selection, reference_source(net_selection) ]

      dimension_mismatch = reference_selection(quantity_unit: 'liter')
      cases << [ dimension_mismatch, reference_source(dimension_mismatch) ]

      alias_unit = reference_selection(reference_unit: 'g')
      cases << [ alias_unit, reference_source(alias_unit) ]

      over_limit = reference_selection(
        reference_price: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX + BigDecimal('1')
      )
      cases << [ over_limit, reference_source(over_limit) ]

      non_finite = reference_selection(reference_price: BigDecimal('NaN'))
      cases << [ non_finite, reference_source(non_finite) ]

      cases.each do |selection, source|
        result = trusted_items([ source ], [ selection ]).sole

        expect(result).not_to have_key(:pricing_source_kind)
      end
    end

    it '全8種のcanonical countable unitと数量境界1を保持する' do
      results = ReceiptQuantityUnit.countable_codes.map do |unit|
        identity = 'azure_structured_item_i0_s100_e115'
        trusted_items(
          [
            {
              raw_text: unit,
              ocr_item_identity: identity,
              pricing_source_kind: 'count_unit_price',
              price: 0,
              quantity: BigDecimal('1'),
              quantity_unit_code: unit,
              quantity_unit_raw: nil,
              original_line_total: 0,
              line_total: 0,
              discount_amount: nil,
              discount_rate: nil,
              position_index: 1
            }
          ],
          [
            count_selection(
              identity: identity,
              item_index: 0,
              position_index: 1,
              price: 0,
              quantity: BigDecimal('1'),
              unit: unit,
              projected_line_total: 0
            )
          ]
        ).sole
      end

      expect(results).to all(include(pricing_source_kind: 'count_unit_price', price: 0, quantity: 1))
    end

    it '明示0円をmissingと区別してexplicit authorityとして保持する' do
      source = {
        raw_text: '無料明細',
        ocr_item_identity: 'azure_structured_item_i0_s100_e115',
        pricing_source_kind: 'explicit_line_total',
        price: nil,
        quantity: BigDecimal('1'),
        quantity_unit_code: 'each',
        original_line_total: 0,
        line_total: 0,
        discount_amount: nil,
        discount_rate: nil,
        position_index: 1
      }

      result = trusted_items([ source ], [ explicit_selection(line_total: 0) ]).sole

      expect(result).to include(
        pricing_source_kind: 'explicit_line_total',
        price: nil,
        original_line_total: BigDecimal('0'),
        line_total: BigDecimal('0')
      )
    end

    it 'layout itemとproposalのpage・name・reference・quantity・total indexが一致するexplicit authorityだけを保持する' do
      identity = 'azure_item_layout_item_p0_name_l1_s6_e12_ref_l2_qty_l3_total_l4'
      proposal_id = 'azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l4_explicit_line_total'
      source = {
        raw_text: 'レイアウト明細',
        ocr_item_identity: identity,
        pricing_source_kind: 'explicit_line_total',
        price: nil,
        quantity: BigDecimal('342'),
        quantity_unit_code: 'gram',
        original_line_total: 1703,
        line_total: 1703,
        discount_amount: nil,
        discount_rate: nil,
        position_index: 1
      }
      selection = explicit_selection(
        identity:,
        proposal_id:,
        line_total: 1703
      )

      result = trusted_items([ source ], [ selection ]).sole

      expect(result).to include(
        pricing_source_kind: 'explicit_line_total',
        price: nil,
        original_line_total: BigDecimal('1703'),
        line_total: BigDecimal('1703')
      )
    end

    it 'layout itemとproposalのstructural index不一致をauthorityにしない' do
      identity = 'azure_item_layout_item_p0_name_l1_s6_e12_ref_l2_qty_l3_total_l4'
      source = {
        raw_text: 'レイアウト明細',
        ocr_item_identity: identity,
        pricing_source_kind: 'explicit_line_total',
        price: nil,
        quantity: BigDecimal('342'),
        quantity_unit_code: 'gram',
        original_line_total: 1703,
        line_total: 1703,
        discount_amount: nil,
        discount_rate: nil,
        position_index: 1
      }
      mismatches = %w[
        azure_item_layout_p1_name_l1_ref_l2_qty_l3_total_l4_explicit_line_total
        azure_item_layout_p0_name_l9_ref_l2_qty_l3_total_l4_explicit_line_total
        azure_item_layout_p0_name_l1_ref_l9_qty_l3_total_l4_explicit_line_total
        azure_item_layout_p0_name_l1_ref_l2_qty_l9_total_l4_explicit_line_total
        azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l9_explicit_line_total
        azure_items_0_explicit_line_total
      ]

      results = mismatches.map do |proposal_id|
        trusted_items(
          [ source ],
          [ explicit_selection(identity:, proposal_id:, line_total: 1703) ]
        ).sole
      end

      expect(results).to all(satisfy { |item| !item.key?(:pricing_source_kind) })
    end

    it 'layout sourceではcount・reference selectionとmalformed identityをauthorityにしない' do
      layout_identity = 'azure_item_layout_item_p0_name_l1_s6_e12_ref_l2_qty_l3_total_l4'
      count_source = {
        raw_text: 'レイアウト明細',
        ocr_item_identity: layout_identity,
        pricing_source_kind: 'count_unit_price',
        price: 120,
        quantity: BigDecimal('2'),
        quantity_unit_code: 'item',
        quantity_unit_raw: nil,
        original_line_total: 240,
        line_total: 240,
        discount_amount: nil,
        discount_rate: nil,
        position_index: 1
      }
      count = count_selection(
        identity: layout_identity,
        proposal_id: 'azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l4_count_unit_price'
      )
      reference = reference_selection(
        identity: layout_identity,
        proposal_id: 'azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l4_reference_quantity_price'
      )
      malformed_identity = layout_identity.sub('_s6_e12_', '_s12_e6_')
      malformed = explicit_selection(
        identity: malformed_identity,
        proposal_id: 'azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l4_explicit_line_total'
      )

      count_result = trusted_items([ count_source ], [ count ]).sole
      reference_result = trusted_items(
        [ reference_source(reference, ocr_item_identity: layout_identity) ],
        [ reference ]
      ).sole
      malformed_result = trusted_items(
        [
          count_source.merge(
            ocr_item_identity: malformed_identity,
            pricing_source_kind: 'explicit_line_total',
            price: nil
          )
        ],
        [ malformed ]
      ).sole

      expect([ count_result, reference_result, malformed_result ]).to all(
        satisfy { |item| !item.key?(:pricing_source_kind) }
      )
    end

    it 'layout identityとproposalのpage・line indexをprovider上限内に制限する' do
      at_limit_identity =
        'azure_item_layout_item_p0_name_l149_s0_e10000000_ref_l149_qty_l149_total_l149'
      at_limit_proposal =
        'azure_item_layout_p0_name_l149_ref_l149_qty_l149_total_l149_explicit_line_total'
      invalid_pairs = [
        [
          'azure_item_layout_item_p1_name_l1_s6_e12_ref_l2_qty_l3_total_l4',
          'azure_item_layout_p1_name_l1_ref_l2_qty_l3_total_l4_explicit_line_total'
        ],
        [
          'azure_item_layout_item_p0_name_l150_s6_e12_ref_l2_qty_l3_total_l4',
          'azure_item_layout_p0_name_l150_ref_l2_qty_l3_total_l4_explicit_line_total'
        ]
      ]
      source = {
        raw_text: 'レイアウト明細',
        pricing_source_kind: 'explicit_line_total',
        price: nil,
        original_line_total: 1703,
        line_total: 1703,
        position_index: 1
      }

      at_limit = trusted_items(
        [ source.merge(ocr_item_identity: at_limit_identity) ],
        [ explicit_selection(identity: at_limit_identity, proposal_id: at_limit_proposal, line_total: 1703) ]
      ).sole
      invalid = invalid_pairs.map do |identity, proposal_id|
        trusted_items(
          [ source.merge(ocr_item_identity: identity) ],
          [ explicit_selection(identity:, proposal_id:, line_total: 1703) ]
        ).sole
      end

      aggregate_failures do
        expect(at_limit[:pricing_source_kind]).to eq('explicit_line_total')
        expect(invalid).to all(satisfy { |item| !item.key?(:pricing_source_kind) })
      end
    end

    it 'reviewable selectionと一致するbounded reasonだけをtrusted authorityと共に保持する' do
      reason = 'item_pricing_mode_uncertain'
      source = {
        raw_text: '確認明細',
        ocr_item_identity: 'azure_structured_item_i0_s100_e115',
        pricing_source_kind: 'explicit_line_total',
        price: nil,
        quantity: BigDecimal('1'),
        quantity_unit_code: 'each',
        original_line_total: 240,
        line_total: 240,
        discount_amount: nil,
        discount_rate: nil,
        position_index: 1,
        needs_review: true,
        review_reasons: [ reason ]
      }
      selection = explicit_selection(review_reason: reason)

      result = trusted_items([ source ], [ selection ]).sole

      expect(result).to include(
        pricing_source_kind: 'explicit_line_total',
        needs_review: true,
        review_reasons: [ reason ]
      )
    end

    it 'selectionとitemのreview markerが不一致ならauthorityだけをfail-closedで破棄する' do
      reason = 'item_pricing_mode_uncertain'
      source = {
        raw_text: '確認明細',
        ocr_item_identity: 'azure_structured_item_i0_s100_e115',
        pricing_source_kind: 'explicit_line_total',
        price: nil,
        quantity: BigDecimal('1'),
        quantity_unit_code: 'each',
        original_line_total: 240,
        line_total: 240,
        discount_amount: nil,
        discount_rate: nil,
        position_index: 1,
        needs_review: true,
        review_reasons: [ reason ]
      }
      cases = [
        [ source.except(:needs_review), explicit_selection(review_reason: reason) ],
        [ source.merge(review_reasons: []), explicit_selection(review_reason: reason) ],
        [ source, explicit_selection ]
      ]

      cases.each do |item_attributes, selection|
        result = trusted_items([ item_attributes ], [ selection ]).sole

        aggregate_failures do
          expect(result[:raw_text]).to eq('確認明細')
          expect(result).not_to have_key(:pricing_source_kind)
        end
      end
    end

    it 'Float・scientific・小数count・alias・measurement unit・raw unitをauthorityにしない' do
      valid = {
        raw_text: '検証明細',
        ocr_item_identity: 'azure_structured_item_i0_s100_e115',
        pricing_source_kind: 'count_unit_price',
        price: 120,
        quantity: BigDecimal('2'),
        quantity_unit_code: 'item',
        quantity_unit_raw: nil,
        original_line_total: 240,
        line_total: 240,
        discount_amount: nil,
        discount_rate: nil,
        position_index: 1
      }
      invalid = [
        valid.merge(price: 120.0),
        valid.merge(price: '1.2e2'),
        valid.merge(quantity: BigDecimal('2.5')),
        valid.merge(quantity_unit_code: '個'),
        valid.merge(quantity_unit_code: 'gram'),
        valid.merge(quantity_unit_raw: '個')
      ]

      invalid.each do |source|
        result = trusted_items([ source ], [ count_selection ]).sole

        expect(result).not_to have_key(:pricing_source_kind)
      end
    end

    it 'source上限ちょうどを許可し、最初の超過をauthorityにしない' do
      source = {
        raw_text: '境界明細',
        ocr_item_identity: 'azure_structured_item_i0_s100_e115',
        pricing_source_kind: 'count_unit_price',
        price: 100,
        quantity: BigDecimal('2'),
        quantity_unit_code: 'item',
        quantity_unit_raw: nil,
        original_line_total: 200,
        line_total: 200,
        discount_amount: nil,
        discount_rate: nil,
        position_index: 1
      }
      selection = count_selection(price: 100, projected_line_total: 200)

      at_limit = described_class.items(
        [ source ],
        trusted_item_calculation_mode_sources: [ selection ],
        item_price_limit: 100,
        item_line_total_limit: 200
      ).sole
      over_price = described_class.items(
        [ source ],
        trusted_item_calculation_mode_sources: [ selection ],
        item_price_limit: 99,
        item_line_total_limit: 200
      ).sole
      over_total = described_class.items(
        [ source ],
        trusted_item_calculation_mode_sources: [ selection ],
        item_price_limit: 100,
        item_line_total_limit: 199
      ).sole

      aggregate_failures do
        expect(at_limit[:pricing_source_kind]).to eq('count_unit_price')
        expect(over_price).not_to have_key(:pricing_source_kind)
        expect(over_total).not_to have_key(:pricing_source_kind)
      end
    end

    it '部分source・discount・source tuple不一致はitemを落とさずauthorityだけを破棄する' do
      valid = {
        raw_text: '検証明細',
        ocr_item_identity: 'azure_structured_item_i0_s100_e115',
        pricing_source_kind: 'explicit_line_total',
        price: nil,
        quantity: BigDecimal('1'),
        quantity_unit_code: 'each',
        original_line_total: 240,
        line_total: 240,
        discount_amount: nil,
        discount_rate: nil,
        position_index: 1
      }
      invalid = [
        valid.merge(original_line_total: nil),
        valid.merge(line_total: 239),
        valid.merge(price: 240),
        valid.merge(discount_amount: 0),
        valid.merge(reference_price_amount: 240)
      ]

      invalid.each do |source|
        result = trusted_items([ source ], [ explicit_selection ]).sole

        aggregate_failures do
          expect(result[:raw_text]).to eq('検証明細')
          expect(result).not_to have_key(:pricing_source_kind)
        end
      end
    end

    it 'identityの欠損・重複・selection重複時は全itemを維持しつつauthorityを一部適用しない' do
      source = {
        raw_text: '検証明細',
        ocr_item_identity: 'azure_structured_item_i0_s100_e115',
        pricing_source_kind: 'count_unit_price',
        price: 120,
        quantity: BigDecimal('2'),
        quantity_unit_code: 'item',
        quantity_unit_raw: nil,
        original_line_total: 240,
        line_total: 240,
        discount_amount: nil,
        discount_rate: nil,
        position_index: 1
      }
      missing = trusted_items([ source.except(:ocr_item_identity) ], [ count_selection ])
      duplicate_items = trusted_items([ source, source.merge(raw_text: '重複') ], [ count_selection ])
      duplicate_selections = trusted_items([ source ], [ count_selection, count_selection ])

      aggregate_failures do
        expect(missing.size).to eq(1)
        expect(duplicate_items.size).to eq(2)
        expect(duplicate_selections.size).to eq(1)
        expect(missing + duplicate_items + duplicate_selections).to all(
          satisfy { |item| !item.key?(:pricing_source_kind) }
        )
      end
    end
  end

  describe '.adjustments' do
    it 'keeps only positive amounts and normalizes enum fallbacks and text' do
      result = described_class.adjustments(
        [
          {
            kind: 'unknown',
            label: '  割引  ',
            amount: 100,
            sign: 'unknown',
            tax_rate: 8,
            source: 'unknown',
            source_text: '  evidence  ',
            source_line_index: 3,
            confidence: '0.9',
            needs_review: true,
            review_reasons: [ ' adjustment_uncertain ', 'adjustment_uncertain' ]
          },
          { kind: 'coupon', amount: 0 },
          { kind: 'coupon', amount: -1 }
        ]
      )

      expect(result).to contain_exactly(
        kind: 'other',
        label: '割引',
        amount: BigDecimal('100'),
        sign: 'discount',
        tax_rate: BigDecimal('0.08'),
        source: 'ai',
        source_text: 'evidence',
        source_line_index: 3,
        confidence: BigDecimal('0.9'),
        needs_review: true,
        review_reasons: [ 'adjustment_uncertain' ],
        position_index: 1
      )
    end
  end

  describe 'scalar normalization' do
    it 'normalizes percent and whole-number tax rates' do
      aggregate_failures do
        expect(described_class.tax_rate('8%')).to eq(BigDecimal('0.08'))
        expect(described_class.tax_rate(8)).to eq(BigDecimal('0.08'))
        expect(described_class.tax_rate('invalid')).to be_nil
      end
    end

    it 'rejects negative calculated amounts without rejecting zero' do
      aggregate_failures do
        expect(described_class.safe_calculated_amount(-1)).to be_nil
        expect(described_class.safe_calculated_amount(0)).to eq(BigDecimal('0'))
        expect(described_class.safe_calculated_amount('invalid')).to be_nil
      end
    end

    it 'normalizes confidence and review reason values' do
      aggregate_failures do
        expect(described_class.confidence('0.5')).to eq(BigDecimal('0.5'))
        expect(described_class.confidence('invalid')).to be_nil
        expect(described_class.review_reasons([ ' one ', '', nil, 'one', :two ])).to eq(%w[one two])
      end
    end
  end
end
