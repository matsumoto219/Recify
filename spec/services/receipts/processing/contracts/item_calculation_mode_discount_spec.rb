require 'rails_helper'

RSpec.describe Receipts::Processing::Contracts::ItemCalculationModeProposalSet do
  def evidence(path, span_start, span_end)
    { source_field_path: path, provider_span_start: span_start, provider_span_end: span_end }
  end

  def discount_context(price: 50, rate: '0.27', amount: 14, total: 36)
    path = 'documents[0].fields.Items[0]'
    identity = 'azure_structured_item_i0_s0_e80'
    total_evidence = evidence("#{path}.TotalPrice", 70, 72)
    candidate = {
      candidate_id: 'azure_items_0_item_calculation_mode',
      item_identity: identity,
      item_index: 0,
      source_provider: 'azure_structured',
      provider_model_id: 'prebuilt-receipt',
      provider_api_version: '2024-11-30',
      string_index_type: 'textElements',
      source_field_path: path,
      provider_span_start: 0,
      provider_span_end: 80,
      destination_evidence: evidence("#{path}.Description", 0, 3),
      printed_line_total: { amount: total.to_s, evidence: total_evidence },
      conflicts: [ 'discount' ],
      options: [
        {
          proposal_id: 'azure_items_0_count_unit_price',
          pricing_source_kind: 'count_unit_price',
          source: { price_amount: price.to_s, quantity: '1', quantity_unit_code: 'piece' },
          evidence: {
            price: evidence("#{path}.Price", 10, 12),
            quantity: evidence("#{path}.Quantity", 20, 21),
            quantity_unit: evidence("#{path}.QuantityUnit", 21, 22)
          },
          discount: {
            amount: amount.to_s,
            rate: rate,
            printed_total_stage: 'after_item_discount',
            evidence: { rate: evidence(path, 40, 42), amount: evidence(path, 50, 52) }
          }
        },
        {
          proposal_id: 'azure_items_0_explicit_line_total',
          pricing_source_kind: 'explicit_line_total',
          source: { line_total_amount: total.to_s },
          evidence: { line_total: total_evidence }
        }
      ]
    }
    item = {
      ocr_item_identity: identity,
      name: '検証品',
      price: price,
      quantity: 1,
      quantity_unit_code: 'piece',
      quantity_unit_raw: nil,
      original_line_total: price,
      line_total: total,
      discount_amount: amount,
      discount_rate: BigDecimal(rate),
      tax_rate: BigDecimal('0'),
      position_index: 0
    }
    snapshot = {
      schema_version: described_class::OCR_RESULT_SCHEMA_VERSION,
      success: true,
      candidates: { items: [ item ], reference_pricing_candidates: [], total_amount: total },
      candidate_counts: {
        items: { actual_count: 1, snapshot_count: 1 },
        reference_pricing_candidates: { actual_count: 0, snapshot_count: 0 },
        item_calculation_mode_candidates: { actual_count: 1, snapshot_count: 1 }
      },
      truncated: {
        items: false,
        reference_pricing_candidates: false,
        item_calculation_mode_candidates: false
      }
    }

    {
      candidate: candidate,
      snapshot: snapshot,
      item: item
    }
  end

  def build_proposals(context)
    described_class.build_all(candidates: [ context.fetch(:candidate) ], ocr_snapshot: context.fetch(:snapshot))
  end

  def recompute_integrity!(proposal, snapshot:)
    context = described_class.send(:ocr_context, snapshot)
    proposal['integrity_checksum'] = described_class.send(:integrity_checksum, proposal, context:)
  end

  def normalized_node_payload(extra_nodes:)
    24.times.to_h do |index|
      value_count = index < extra_nodes ? 5 : 4
      [ "key_#{index}", Array.new(value_count, 0) ]
    end
  end

  def before_discount_context(count: false)
    context = discount_context
    candidate = context[:candidate]
    discount = candidate[:options].first[:discount].deep_dup
    discount[:printed_total_stage] = 'before_item_discount'
    total_evidence = evidence('documents[0].fields.Items[0].TotalPrice', 30, 32)
    candidate[:printed_line_total] = { amount: '50', evidence: total_evidence }
    candidate[:options].last.merge!(
      source: { line_total_amount: '50' },
      evidence: { line_total: total_evidence },
      discount: discount
    )
    candidate[:options].first[:discount] = discount.deep_dup
    candidate[:options].shift unless count
    context
  end

  def absolute_reference_discount_context
    path = 'documents[0].fields.Items[0]'
    identity = 'azure_structured_item_i0_s0_e80'
    total_evidence = evidence("#{path}.TotalPrice", 30, 34)
    discount = {
      amount: '150',
      printed_total_stage: 'before_item_discount',
      evidence: { amount: evidence(path, 40, 45) }
    }
    candidate = {
      candidate_id: 'azure_items_0_item_calculation_mode',
      item_identity: identity,
      item_index: 0,
      source_provider: 'azure_structured',
      provider_model_id: 'prebuilt-receipt',
      provider_api_version: '2024-11-30',
      string_index_type: 'textElements',
      source_field_path: path,
      provider_span_start: 0,
      provider_span_end: 80,
      destination_evidence: evidence("#{path}.Description", 0, 4),
      printed_line_total: { amount: '7454', evidence: total_evidence },
      conflicts: %w[discount reference_expression],
      options: [
        {
          proposal_id: 'azure_items_0_explicit_line_total',
          pricing_source_kind: 'explicit_line_total',
          source: { line_total_amount: '7454' },
          evidence: { line_total: total_evidence },
          discount: discount
        }
      ]
    }
    item = {
      ocr_item_identity: identity,
      name: '検証品',
      price: 149,
      quantity: BigDecimal('50.03'),
      quantity_unit_code: 'liter',
      quantity_unit_raw: nil,
      original_line_total: 7454,
      line_total: 7304,
      discount_amount: 150,
      discount_rate: nil,
      tax_rate: BigDecimal('0.1'),
      position_index: 0
    }
    reference_component = lambda do |field, amount, span_start, span_end|
      {
        amount: amount,
        evidence: {
          source_provider: 'azure_structured',
          source_field_path: "#{path}.#{field}",
          item_index: 0,
          provider_span_start: span_start,
          provider_span_end: span_end
        }
      }
    end
    line = lambda do |source_path, line_index, span_start, span_end, source_provider: 'azure_structured'|
      {
        source_provider: source_provider,
        source_field_path: source_path,
        page_index: 0,
        line_index: line_index,
        string_index_type: 'textElements',
        provider_span_start: span_start,
        provider_span_end: span_end
      }
    end
    reference = {
      candidate_id: 'azure_items_0_reference_pricing',
      item_index: 0,
      validation_state: 'valid',
      rejection_reasons: [],
      reference_price: reference_component.call('Price', '149', 10, 13),
      reference_quantity: reference_component.call('QuantityUnit', '1', 20, 21).merge(
        unit_code: 'liter',
        unit_status: 'known',
        origin: 'implicit_per_unit'
      ),
      purchased_quantity: reference_component.call('Quantity', '50.03', 14, 19).merge(
        unit_code: 'liter',
        unit_status: 'known'
      ),
      reference_price_tax_inclusion: 'gross',
      tax_inclusion_evidence: {
        kind: 'single_item_receipt_inner_tax_summary',
        string_index_type: 'textElements',
        policy_contract_version: 'reference_pricing_single_structured_item_gross_policy_v1',
        item_parent: {
          source_provider: 'azure_structured',
          source_field_path: path,
          item_index: 0,
          provider_span_start: 0,
          provider_span_end: 80
        },
        tax_detail_parent: {
          source_provider: 'azure_structured',
          source_field_path: 'documents[0].fields.TaxDetails[0]',
          tax_detail_index: 0,
          provider_span_start: 90,
          provider_span_end: 105
        },
        tax_description: line.call(
          'documents[0].fields.TaxDetails[0].Description', 4, 90, 95
        ).merge(tax_detail_index: 0),
        tax_amount: line.call(
          'documents[0].fields.TaxDetails[0].Amount', 5, 96, 99
        ).merge(tax_detail_index: 0, amount: 664),
        document_tax_total: line.call(
          'documents[0].fields.TotalTax', 5, 96, 99
        ).merge(amount: 664),
        summary_total: line.call(
          'pages[0].lines[7]', 7, 110, 114, source_provider: 'azure_document_total'
        ).merge(amount: 7304)
      },
      printed_line_total: {
        amount: '7454',
        evidence: {
          source_provider: 'azure_structured',
          source_field_path: "#{path}.TotalPrice",
          item_index: 0,
          provider_span_start: 30,
          provider_span_end: 34
        }
      },
      corroboration: {
        exact_amount: { numerator: '745447', denominator: '100' },
        projected_amount: 7454,
        printed_line_total: '7454',
        rounding_matches: %w[floor half_up]
      }
    }
    snapshot = {
      schema_version: described_class::OCR_RESULT_SCHEMA_VERSION,
      success: true,
      candidates: {
        items: [ item ],
        reference_pricing_candidates: [ reference ],
        total_amount: 7304,
        tax_amount: 664
      },
      candidate_counts: {
        items: { actual_count: 1, snapshot_count: 1 },
        reference_pricing_candidates: { actual_count: 1, snapshot_count: 1 },
        item_calculation_mode_candidates: { actual_count: 1, snapshot_count: 1 }
      },
      truncated: {
        items: false,
        reference_pricing_candidates: false,
        item_calculation_mode_candidates: false
      }
    }

    { candidate: candidate, snapshot: snapshot, item: item }
  end

  def decision_for(context, item_line_total_limit: 999_999, count_tax_semantics: 'reproducible_as_recorded')
    Receipts::Processing::Contracts::ItemCalculationModeDecision.call(
      item_identity: context[:item][:ocr_item_identity],
      item_proposals: build_proposals(context),
      ocr_snapshot: context[:snapshot],
      count_tax_semantics: count_tax_semantics,
      item_price_limit: 999_999,
      item_line_total_limit: item_line_total_limit
    )
  end

  def amount_for(params)
    ReceiptAmountService.call(
      receipt: params[:receipt_attributes],
      receipt_items: params[:receipt_items_attributes],
      receipt_tax_details: params[:receipt_tax_details_attributes],
      receipt_adjustments: params[:receipt_adjustments_attributes],
      receipt_payments: params[:receipt_payments_attributes],
      context: :analysis
    )
  end

  def application_context(context)
    params = {
      receipt_attributes: { total_amount: context[:item][:line_total], tax_amount: 0, tax_rate: 0 },
      receipt_items_attributes: [ context[:item].deep_dup ],
      receipt_tax_details_attributes: [],
      receipt_adjustments_attributes: [],
      receipt_payments_attributes: [],
      review_reasons: []
    }
    ocr_result = context[:snapshot].merge(adoption_proposals: { item_calculation_modes: build_proposals(context) })

    {
      params: params,
      ocr_result: ocr_result,
      amount_result: amount_for(params)
    }
  end

  def apply(context, &amount_calculator)
    Receipts::Processing::Pipeline::FinalizeStep::ItemCalculationModeApplicator.call(
      params: context[:params],
      ocr_result: context[:ocr_result],
      preliminary_amount_result: context[:amount_result],
      automatic_application_allowed: true,
      item_price_limit: 999_999,
      item_line_total_limit: 999_999,
      &(amount_calculator || method(:amount_for))
    )
  end

  def uniform_net_discount_context
    context = before_discount_context(count: true)
    context[:item][:tax_rate] = BigDecimal('0.1')
    application = application_context(context)
    application[:params][:receipt_attributes].merge!(subtotal_amount: 36, tax_amount: 3, total_amount: 39, tax_rate: BigDecimal('0.1'))
    application[:params][:receipt_tax_details_attributes] = [ { description: '外税10%', net_amount: 36, amount: 3, rate: BigDecimal('0.1') } ]
    application[:amount_result] = amount_for(application[:params])
    application
  end

  def rounding_discount_context
    context = before_discount_context(count: true)
    context[:item].merge!(price: 318, original_line_total: 318, line_total: 190, discount_amount: 128, discount_rate: BigDecimal('0.4'))
    context[:snapshot][:candidates][:total_amount] = 190
    context[:candidate][:printed_line_total][:amount] = '318'
    context[:candidate][:options].first[:source][:price_amount] = '318'
    context[:candidate][:options].last[:source][:line_total_amount] = '318'
    context[:candidate][:options].each { |option| option[:discount].merge!(amount: '128', rate: '0.4') }
    context
  end

  it 'keeps complete count evidence but selects absolute explicit source when only rate rounding disagrees' do
    context = rounding_discount_context

    expect(build_proposals(context)&.sole&.fetch('options')&.size).to eq(2)
    expect(decision_for(context)).to have_attributes(
      state: 'reviewable',
      selected_pricing_source_kind: 'explicit_line_total',
      projected_line_total: 190
    )
  end

  it 'applies absolute explicit discount without promoting the printed diagnostic rate' do
    context = application_context(rounding_discount_context)
    result = apply(context)

    expect(result).to be_applied
    expect(result.params[:receipt_items_attributes].sole).to include(
      pricing_source_kind: 'explicit_line_total',
      price: nil,
      original_line_total: 318,
      discount_amount: 128,
      discount_rate: nil,
      line_total: 190
    )
    expect(result.amount_result[:resolved]).to eq(context[:amount_result][:resolved])
  end

  it 'supports a complete explicit-only before-discount source without inventing count evidence' do
    context = rounding_discount_context
    context[:candidate][:options].shift

    expect(build_proposals(context).sole.fetch('options').size).to eq(1)
    expect(decision_for(context)).to have_attributes(
      state: 'reviewable',
      selected_pricing_source_kind: 'explicit_line_total',
      projected_line_total: 190
    )
    expect(apply(application_context(context))).to be_applied
  end

  it 'does not recover malformed or unrelated count evidence as a rounding fallback' do
    mutations = [
      ->(context) { context[:candidate][:options].first[:source][:price_amount] = '317' },
      ->(context) { context[:candidate][:options].first[:source][:quantity] = '0' },
      ->(context) { context[:candidate][:options].first[:source][:quantity_unit_code] = 'unknown' },
      ->(context) { context[:candidate][:options].first[:source][:unexpected] = '318' },
      ->(context) { context[:candidate][:options].first[:discount][:printed_total_stage] = 'after_item_discount' },
      ->(context) { context[:candidate][:options].first[:discount][:evidence][:amount][:provider_span_end] = 90 },
      ->(context) { context[:candidate][:options].each { |option| option[:discount][:rate] = '0.4001' } },
      ->(context) { context[:candidate][:options].each { |option| option[:discount][:rate] = '1' } },
      ->(context) { context[:candidate][:options].each { |option| option[:discount][:amount] = '319' } }
    ]

    mutations.each do |mutation|
      context = rounding_discount_context
      mutation.call(context)
      expect(build_proposals(context)).to be_nil
    end

    expect(decision_for(rounding_discount_context, item_line_total_limit: 317)).not_to be_reviewable
  end

  it 'does not allow absolute fallback to change any computed amount or keep an inferred rate' do
    mutations = [
      ->(amount) { amount[:computed][:items].sole[:original_line_total] += 1 },
      ->(amount) { amount[:computed][:items].sole[:discount_amount] += 1 },
      ->(amount) { amount[:computed][:items].sole[:discount_rate] = BigDecimal('0.4') },
      ->(amount) { amount[:computed][:items].sole[:line_total] += 1 },
      ->(amount) { amount[:computed][:items].sole[:tax_rate] = BigDecimal('0.08') },
      ->(amount) { amount[:resolved][:total] += 1 }
    ]

    mutations.each do |mutation|
      context = application_context(rounding_discount_context)
      result = apply(context) do |params|
        amount_for(params).deep_dup.tap { |amount| mutation.call(amount) }
      end

      expect(result).not_to be_applied
    end
  end

  it 'does not canonicalize another item discount or financial fields during absolute fallback' do
    %i[discount_rate discount_amount line_total].each do |field|
      context = application_context(rounding_discount_context)
      other_item = {
        name: '別検証品',
        price: nil,
        quantity: 1,
        line_total: 100,
        original_line_total: 100,
        tax_rate: BigDecimal('0'),
        position_index: 1
      }
      context[:params][:receipt_items_attributes] << other_item.deep_dup
      context[:ocr_result][:candidates][:items] << other_item.deep_dup
      context[:ocr_result][:candidate_counts][:items] = { actual_count: 2, snapshot_count: 2 }
      context[:params][:receipt_attributes][:total_amount] = 290
      context[:amount_result] = amount_for(context[:params])
      expect(apply(context)).to be_applied

      result = apply(context) do |params|
        amount_for(params).deep_dup.tap { |amount| amount[:computed][:items].last[field] = 1 }
      end

      expect(result).not_to be_applied
    end
  end

  it 'saves absolute explicit source through unchanged editing, source changes and finalize retry' do
    context = rounding_discount_context
    ocr = {
      success: true,
      candidates: context[:snapshot][:candidates].merge(
        item_calculation_mode_candidates: [ context[:candidate] ],
        tax_amount: 0,
        tax_rate: BigDecimal('0'),
        tax_details: [],
        payments: [],
        adjustment_candidates: []
      )
    }
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = Receipts::Processing.start(receipt: receipt, source: 'upload').run
    Receipts::Processing.record_ocr_snapshot(run, ocr)
    Receipts::Processing.record_finalize_decision(
      run,
      Receipts::Processing::Contracts::FinalizeDecision.new(
        finalize_strategy: 'ocr_only',
        error_code: nil,
        error_message: nil,
        receipt_attributes: {},
        ocr_result: nil,
        ai_result: nil,
        metadata: {}
      )
    )
    expect(Receipts::Processing.run_finalize(run.reload).next_step).to eq(:done)
    item = receipt.reload.receipt_items.sole
    expect(item).to have_attributes(
      pricing_source_kind: 'explicit_line_total',
      price: nil,
      original_line_total: 318,
      discount_amount: 128,
      discount_rate: nil,
      line_total: 190
    )
    expect(item.review_reasons).to include('item_pricing_mode_uncertain')

    [ [ 318, 128, 190 ], [ 400, 128, 272 ], [ 400, 100, 300 ] ].each do |original, discount, total|
      attributes = { 'receipt_items_attributes' => { '0' => { 'id' => item.id.to_s, 'original_line_total' => original.to_s, 'discount_amount' => discount.to_s } } }
      input = Receipts::Editing.build_input(receipt: receipt, permitted: attributes)
      change_set = Receipts::Editing.change_set(receipt: receipt, permitted: attributes)
      amount = ReceiptAmountService.call(
        receipt: receipt.attributes.symbolize_keys.merge(receipt.amount_source_semantics_for_edit).merge(subtotal_amount: nil, tax_amount: nil, total_amount: nil),
        receipt_items: input.receipt_items,
        receipt_tax_details: [],
        receipt_adjustments: input.receipt_adjustments,
        receipt_payments: input.receipt_payments,
        context: :edit_save
      )
      Receipts::Editing.apply_amount_result!(
        receipt: receipt,
        attributes: attributes,
        amount_result: amount,
        context: :edit_save,
        change_set: change_set,
        tax_details_recalculated: false
      )
      expect(Receipts::Editing.update_manual(receipt: receipt, attributes: attributes, items_missing: false)).to be_saved
      expect(item.reload).to have_attributes(
        original_line_total: original,
        discount_amount: discount,
        discount_rate: nil,
        line_total: total
      )
    end

    before = item.attributes
    expect(Receipts::Processing.run_finalize(run.reload).next_step).to eq(:skipped)
    expect(item.reload.attributes).to eq(before)
  ensure
    receipt&.image&.purge
  end

  it 'round-trips a complete same-item discount without changing the existing count source tuple' do
    context = discount_context
    proposals = build_proposals(context)

    expect(proposals).not_to be_nil
    expect(described_class.from_snapshot(
      JSON.parse(JSON.generate(proposals)),
      ocr_snapshot: context[:snapshot]
    )).to eq(proposals)
    expect(proposals.sole.dig('options', 0, 'source').keys).to match_array(described_class::COUNT_SOURCE_KEYS)
  end

  it 'round-trips the before-discount explicit source without replacing it with the derived amount' do
    context = before_discount_context
    proposals = build_proposals(context)

    expect(proposals).not_to be_nil
    expect(described_class.from_snapshot(JSON.parse(JSON.generate(proposals)), ocr_snapshot: context[:snapshot])).to eq(proposals)
    expect(proposals.sole.dig('options', 0, 'source')).to eq('line_total_amount' => '50')
  end

  it 'shares one discount proof between count and explicit alternatives without treating it as two discounts' do
    context = before_discount_context(count: true)

    expect(build_proposals(context)).not_to be_nil
    expect(decision_for(context)).to have_attributes(
      state: 'confirmed',
      selected_pricing_source_kind: 'count_unit_price',
      projected_line_total: 36
    )
  end

  it 'round-trips an exact same-item reference proposal with an absolute discount' do
    context = absolute_reference_discount_context
    proposals = build_proposals(context)

    aggregate_failures do
      expect(proposals).not_to be_nil
      expect(JSON.generate(proposals.sole).bytesize).to be <= described_class::MAX_SERIALIZED_BYTES
      expect(proposals.sole.fetch('options').pluck('pricing_source_kind')).to eq(%w[
        reference_quantity_price
        explicit_line_total
      ])
      expect(proposals.sole.fetch('options').pluck('discount').uniq).to eq([
        {
          'amount' => '150',
          'printed_total_stage' => 'before_item_discount',
          'evidence' => {
            'amount' => evidence('documents[0].fields.Items[0]', 40, 45).deep_stringify_keys
          }
        }
      ])
      expect(described_class.from_snapshot(
        JSON.parse(JSON.generate(proposals)),
        ocr_snapshot: JSON.parse(JSON.generate(context[:snapshot]))
      )).to eq(proposals)
    end
  end

  it 'fails closed at the first node beyond the normalized bound for a discounted proposal' do
    within_bound = normalized_node_payload(extra_nodes: 15)
    over_bound = normalized_node_payload(extra_nodes: 16)

    aggregate_failures do
      expect(described_class.send(:bounded_normalized_hash, within_bound)).to eq(within_bound)
      expect(described_class.send(:bounded_normalized_hash, over_bound)).to be_nil
      expect(described_class.send(:bounded_normalized_hash, { 'optional' => nil })).to eq('optional' => nil)
    end
  end

  it 'confirms the reference proposal when its discounted projection matches the printed final amount' do
    expect(decision_for(absolute_reference_discount_context)).to have_attributes(
      state: 'confirmed',
      reason: 'formula_matches_printed_total',
      selected_pricing_source_kind: 'reference_quantity_price',
      projected_line_total: 7304
    )
  end

  it 'validates the undiscounted reference projection bound separately from the final amount' do
    expect(decision_for(absolute_reference_discount_context, item_line_total_limit: 7453)).to be_unresolved
    expect(decision_for(absolute_reference_discount_context, item_line_total_limit: 7454)).to be_confirmed
  end

  it 'fails closed for a rated, foreign, later-stage or inconsistent absolute reference discount' do
    mutations = [
      ->(context) { context[:candidate][:options].sole[:discount][:rate] = '0.02' },
      ->(context) { context[:candidate][:options].sole[:discount][:printed_total_stage] = 'after_item_discount' },
      ->(context) { context[:candidate][:options].sole[:discount][:evidence][:amount][:source_field_path] = 'documents[0].fields.Items[1]' },
      ->(context) { context[:candidate][:options].sole[:discount][:amount] = '151' },
      ->(context) { context[:item][:discount_rate] = BigDecimal('0.02') },
      ->(context) { context[:item][:discount_amount] = 151 },
      ->(context) { context[:item][:original_line_total] = 7453 },
      ->(context) { context[:item][:line_total] = 7303 }
    ]

    mutations.each do |mutation|
      context = absolute_reference_discount_context
      mutation.call(context)
      expect(build_proposals(context)).to be_nil
    end
  end

  it 'rejects diverging reference and explicit discount evidence after checksum recomputation' do
    context = absolute_reference_discount_context
    proposals = build_proposals(context)
    proposals.sole.fetch('options').first.fetch('discount')['amount'] = '151'
    recompute_integrity!(proposals.sole, snapshot: context[:snapshot])

    expect(described_class.from_snapshot(
      JSON.parse(JSON.generate(proposals)),
      ocr_snapshot: context[:snapshot]
    )).to be_nil
  end

  it 'rejects a discounted projection and summary Total mismatch after checksum recomputation' do
    context = absolute_reference_discount_context
    proposals = build_proposals(context)
    context[:snapshot][:candidates][:total_amount] = 7303
    context[:snapshot][:candidates][:reference_pricing_candidates].sole[:tax_inclusion_evidence][:summary_total][:amount] = 7303
    proposals.sole.dig('options', 0, 'evidence', 'tax_inclusion', 'summary_total')['amount'] = 7303
    recompute_integrity!(proposals.sole, snapshot: context[:snapshot])

    expect(described_class.from_snapshot(
      JSON.parse(JSON.generate(proposals)),
      ocr_snapshot: context[:snapshot]
    )).to be_nil
  end

  it 'confirms a complete discounted count source when uniform net semantics are reproducible' do
    expect(decision_for(before_discount_context(count: true), count_tax_semantics: 'reproducible_uniform_net')).to have_attributes(
      state: 'confirmed',
      selected_pricing_source_kind: 'count_unit_price',
      projected_line_total: 36
    )
  end

  it 'preserves uniform net discount sources and receipt gross amounts with printed tax details' do
    context = uniform_net_discount_context
    expect(context.dig(:amount_result, :calculation_profile)).to include(
      receipt_tax_basis: :tax_added_to_subtotal,
      item_amount_basis: :line_total_as_net
    )
    result = apply(context)

    expect(result).to be_applied
    expect(result.decisions.sole).to be_confirmed
    expect(result.params[:receipt_items_attributes].sole).to include(
      pricing_source_kind: 'count_unit_price',
      price: 50,
      original_line_total: 50,
      discount_amount: 14,
      discount_rate: BigDecimal('0.27'),
      line_total: 36
    )
    expect(result.amount_result[:resolved]).to eq(context[:amount_result][:resolved])
    expect(result.amount_result[:resolved]).to include(subtotal: 36, tax: 3, total: 39)
  end

  it 'rejects changes to any uniform net computed source, discount or receipt amount' do
    mutations = [
      ->(result) { result[:computed][:items].sole[:price] += 1 },
      ->(result) { result[:computed][:items].sole[:quantity] += 1 },
      ->(result) { result[:computed][:items].sole[:original_line_total] -= 1 },
      ->(result) { result[:computed][:items].sole[:line_total] += 1 },
      ->(result) { result[:computed][:items].sole[:discount_amount] += 1 },
      ->(result) { result[:computed][:items].sole[:discount_rate] = BigDecimal('0.28') },
      ->(result) { result[:computed][:items].sole[:tax_rate] = BigDecimal('0.08') },
      ->(result) { result[:resolved][:total] += 1 }
    ]

    mutations.each do |mutation|
      context = uniform_net_discount_context
      result = apply(context) do |params|
        amount_for(params).deep_dup.tap { |amount| mutation.call(amount) }
      end

      expect(result).not_to be_applied
    end
  end

  it 'does not confirm a uniform net discount with conflicting tax semantics' do
    %i[receipt_tax_basis item_amount_basis tax_detail_amount_basis].each do |field|
      context = uniform_net_discount_context
      context[:amount_result][:computed][field] = :unknown

      expect(apply(context).decisions.sole).to have_attributes(state: 'reviewable', reason: 'count_tax_semantics_unknown')
    end
  end

  it 'keeps incomplete, mismatched and boundary discount sources ineligible for uniform net confirmation' do
    mutations = [
      ->(context) { context[:item][:discount_amount] = 13 },
      ->(context) { context[:item][:discount_rate] = nil },
      ->(context) { context[:candidate][:options].first[:discount][:rate] = '1' },
      ->(context) { context[:candidate][:options].first[:discount][:rate] = '0' },
      ->(context) { context[:candidate][:options].first[:discount][:amount] = '51' }
    ]

    mutations.each do |mutation|
      context = before_discount_context(count: true)
      mutation.call(context)
      expect(decision_for(context, count_tax_semantics: 'reproducible_uniform_net')).not_to be_confirmed
    end

    expect(decision_for(before_discount_context(count: true), count_tax_semantics: 'reproducible_uniform_net', item_line_total_limit: 49)).not_to be_confirmed
    expect(decision_for(discount_context(price: 1, rate: '0.01', amount: 0, total: 1), count_tax_semantics: 'reproducible_uniform_net')).to be_confirmed
  end

  it 'confirms exact uniform net discount sources at HALF_UP boundaries and percentage endpoints' do
    [
      { price: 49, rate: '0.27', amount: 13, total: 36 },
      { price: 50, rate: '0.27', amount: 14, total: 36 },
      { price: 51, rate: '0.27', amount: 14, total: 37 },
      { price: 100, rate: '0.01', amount: 1, total: 99 },
      { price: 100, rate: '0.99', amount: 99, total: 1 }
    ].each do |values|
      expect(decision_for(discount_context(**values), count_tax_semantics: 'reproducible_uniform_net')).to have_attributes(
        state: 'confirmed',
        projected_line_total: values[:total]
      )
    end
  end

  it 'keeps an unrelated item and receipt coupon unchanged without hiding uncertain tax semantics' do
    context = uniform_net_discount_context
    other_item = {
      name: '別検証品',
      quantity: 1,
      quantity_unit_code: 'piece',
      price: nil,
      original_line_total: 100,
      line_total: 100,
      tax_rate: BigDecimal('0.1'),
      position_index: 1
    }
    context[:params][:receipt_items_attributes] << other_item.deep_dup
    context[:ocr_result][:candidates][:items] << other_item.deep_dup
    context[:ocr_result][:candidate_counts][:items] = { actual_count: 2, snapshot_count: 2 }
    context[:params][:receipt_adjustments_attributes] = [
      { kind: 'coupon', label: 'クーポン', amount: 10, sign: -1, tax_rate: BigDecimal('0.1'), effect: 'purchase_adjustment' }
    ]
    context[:params][:receipt_attributes].merge!(subtotal_amount: 126, tax_amount: 12, total_amount: 138)
    context[:params][:receipt_tax_details_attributes] = [ { description: '外税10%', net_amount: 126, amount: 12, rate: BigDecimal('0.1') } ]
    context[:amount_result] = amount_for(context[:params])
    result = apply(context)

    expect(result).to be_applied
    expect(result.decisions.sole).to have_attributes(state: 'reviewable', reason: 'count_tax_semantics_unknown')
    expect(result.params[:receipt_items_attributes].last).to eq(other_item)
    expect(result.params[:receipt_adjustments_attributes]).to eq(context[:params][:receipt_adjustments_attributes])
    expect(result.amount_result[:resolved]).to eq(context[:amount_result][:resolved])
    expect(result.amount_result[:resolved]).to include(subtotal: 126, tax: 12, total: 138)
    expect(result.params[:receipt_items_attributes].first).to include(discount_amount: 14, line_total: 36)
  end

  it 'persists uniform net discount sources and preserves them through editing and retry' do
    context = before_discount_context(count: true)
    context[:item][:tax_rate] = BigDecimal('0.1')
    ocr = {
      success: true,
      candidates: context[:snapshot][:candidates].merge(
        country_region: 'JPN',
        item_calculation_mode_candidates: [ context[:candidate] ],
        subtotal_amount: 36,
        tax_amount: 3,
        total_amount: 39,
        tax_rate: BigDecimal('0.1'),
        tax_details: [ { description: '外税10%', net_amount: 36, amount: 3, rate: BigDecimal('0.1') } ],
        payments: [],
        adjustment_candidates: []
      )
    }
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = Receipts::Processing.start(receipt: receipt, source: 'upload').run
    Receipts::Processing.record_ocr_snapshot(run, ocr)
    Receipts::Processing.record_finalize_decision(
      run,
      Receipts::Processing::Contracts::FinalizeDecision.new(
        finalize_strategy: 'ocr_only',
        error_code: nil,
        error_message: nil,
        receipt_attributes: {},
        ocr_result: nil,
        ai_result: nil,
        metadata: {}
      )
    )
    expect(Receipts::Processing.run_finalize(run).next_step).to eq(:done)
    item = receipt.reload.receipt_items.sole
    expect(item).to have_attributes(
      pricing_source_kind: 'count_unit_price',
      price: 50,
      quantity: BigDecimal('1'),
      original_line_total: 50,
      discount_amount: 14,
      discount_rate: BigDecimal('0.27'),
      line_total: 36
    )
    expect(item.review_reasons).not_to include('item_pricing_mode_uncertain')
    expect(receipt).to have_attributes(subtotal_amount: 36, tax_amount: 3, total_amount: 39)

    [ [ '1', 50, 14, 36, 39 ], [ '2', 100, 27, 73, 80 ] ].each do |quantity, original, discount, net, gross|
      attributes = { 'receipt_items_attributes' => { '0' => { 'id' => item.id.to_s, 'quantity' => quantity } } }
      input = Receipts::Editing.build_input(receipt: receipt, permitted: attributes)
      change_set = Receipts::Editing.change_set(receipt: receipt, permitted: attributes)
      receipt_amounts = receipt.attributes.symbolize_keys.merge(receipt.amount_source_semantics_for_edit)
      receipt_amounts.merge!(subtotal_amount: nil, tax_amount: nil, total_amount: nil) if change_set.derived_purchase_inputs_changed?
      amount = ReceiptAmountService.call(
        receipt: receipt_amounts,
        receipt_items: input.receipt_items,
        receipt_tax_details: change_set.derived_purchase_inputs_changed? ? [] : receipt.receipt_tax_details,
        receipt_adjustments: input.receipt_adjustments,
        receipt_payments: input.receipt_payments,
        context: :edit_save
      )
      Receipts::Editing.apply_amount_result!(
        receipt: receipt,
        attributes: attributes,
        amount_result: amount,
        context: :edit_save,
        change_set: change_set,
        tax_details_recalculated: false
      )
      expect(Receipts::Editing.update_manual(receipt: receipt, attributes: attributes, items_missing: false)).to be_saved
      expect(item.reload).to have_attributes(
        price: 50,
        original_line_total: original,
        discount_amount: discount,
        discount_rate: BigDecimal('0.27'),
        line_total: net
      )
      expect(receipt.reload.total_amount).to eq(gross)
    end

    source_after_edit = item.reload.attributes
    expect(Receipts::Processing.run_finalize(run.reload).next_step).to eq(:skipped)
    expect(item.reload.attributes).to eq(source_after_edit)
  ensure
    receipt&.image&.purge
  end

  it 'rejects different discount evidence between alternatives and a missing before-total stage' do
    context = before_discount_context(count: true)
    context[:candidate][:options].last[:discount][:evidence][:amount][:provider_span_start] += 1
    expect(build_proposals(context)).to be_nil

    context = before_discount_context
    context[:candidate][:options].sole[:discount][:printed_total_stage] = 'after_item_discount'
    expect(build_proposals(context)).to be_nil
  end

  it 'rejects stale, foreign, overlapping and partial before-discount source evidence' do
    mutations = [
      ->(context) { context[:candidate][:options].sole[:discount].delete(:amount) },
      ->(context) { context[:candidate][:options].sole[:discount][:amount] = '51' },
      ->(context) { context[:candidate][:options].sole[:discount][:evidence][:amount][:provider_span_start] = 29 },
      ->(context) { context[:candidate][:options].sole[:discount][:evidence][:rate][:source_field_path] = 'documents[0].fields.Items[1]' },
      ->(context) { context[:candidate][:options].sole[:discount][:evidence][:rate][:provider_span_end] = 81 },
      ->(context) { context[:candidate][:conflicts] << 'package' },
      ->(context) { context[:item][:discount_rate] = nil },
      ->(context) { context[:item][:discount_amount] = 13 },
      ->(context) { context[:item][:original_line_total] = 36 }
    ]

    mutations.each do |mutation|
      context = before_discount_context
      mutation.call(context)
      expect(build_proposals(context)).to be_nil
    end
  end

  it 'selects the discounted explicit source using the projected amount' do
    expect(decision_for(before_discount_context)).to have_attributes(
      state: 'confirmed',
      selected_pricing_source_kind: 'explicit_line_total',
      projected_line_total: 36
    )
  end

  it 'applies a discounted explicit source through final normalization without subtracting twice' do
    result = apply(application_context(before_discount_context))

    expect(result).to be_applied
    normalized = Receipts::Processing::Pipeline::FinalizeStep::AttributeNormalizer.items(
      result.params[:receipt_items_attributes],
      trusted_item_calculation_mode_sources: result.selections,
      item_price_limit: 999_999,
      item_line_total_limit: 999_999
    )
    expect(normalized.sole).to include(
      pricing_source_kind: 'explicit_line_total',
      price: nil,
      original_line_total: 50,
      line_total: 36,
      discount_amount: 14,
      discount_rate: BigDecimal('0.27')
    )
  end

  it 'persists the discounted explicit source and keeps it unchanged on finalize retry' do
    context = before_discount_context
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = Receipts::Processing.start(receipt: receipt, source: 'upload').run
    ocr = {
      success: true,
      candidates: context[:snapshot][:candidates].merge(
        item_calculation_mode_candidates: [ context[:candidate] ],
        tax_amount: 0,
        tax_rate: BigDecimal('0'),
        tax_details: [],
        payments: [],
        adjustment_candidates: []
      )
    }
    Receipts::Processing.record_ocr_snapshot(run, ocr)
    Receipts::Processing.record_finalize_decision(
      run,
      Receipts::Processing::Contracts::FinalizeDecision.new(
        finalize_strategy: 'ocr_only',
        error_code: nil,
        error_message: nil,
        receipt_attributes: {},
        ocr_result: nil,
        ai_result: nil,
        metadata: {}
      )
    )

    result = Receipts::Processing.run_finalize(run)

    expect(result.next_step).to eq(:done)
    expect(receipt.reload.receipt_items.sole).to have_attributes(
      pricing_source_kind: 'explicit_line_total',
      price: nil,
      original_line_total: 50,
      line_total: 36,
      discount_amount: 14,
      discount_rate: BigDecimal('0.27')
    )
    saved = receipt.receipt_items.sole.attributes
    submitted = {
      'receipt_items_attributes' => {
        '0' => {
          'id' => saved.fetch('id').to_s,
          'pricing_source_kind' => 'explicit_line_total',
          'original_line_total' => '50',
          'discount_rate' => '27'
        }
      }
    }
    attributes = Receipts::EditForm.call(receipt: receipt, attributes: submitted)
    input = Receipts::Editing.build_input(receipt: receipt, permitted: attributes)
    edited_amount = ReceiptAmountService.call(
      receipt: receipt.attributes.symbolize_keys.merge(receipt.amount_source_semantics_for_edit),
      receipt_items: input.receipt_items,
      receipt_tax_details: receipt.receipt_tax_details,
      receipt_adjustments: input.receipt_adjustments,
      receipt_payments: input.receipt_payments,
      context: :edit_save
    )
    expect(edited_amount.dig(:computed, :items).sole).to include(
      original_line_total: 50,
      line_total: 36,
      discount_amount: 14,
      discount_rate: BigDecimal('0.27')
    )
    expect(Receipts::Processing.run_finalize(run.reload).next_step).to eq(:skipped)
    expect(receipt.reload.receipt_items.sole.attributes).to eq(saved)
  end

  it 'rejects missing, foreign, overlapping, malformed and inconsistent discount evidence' do
    mutations = [
      ->(candidate) { candidate[:options].first[:discount].delete(:amount) },
      ->(candidate) { candidate[:options].first[:discount].delete(:rate) },
      ->(candidate) { candidate[:options].first[:discount][:rate] = '0' },
      ->(candidate) { candidate[:options].first[:discount][:rate] = '0.2701' },
      ->(candidate) { candidate[:options].first[:discount][:rate] = '1' },
      ->(candidate) { candidate[:options].first[:discount][:amount] = '13' },
      ->(candidate) { candidate[:options].first[:discount][:extra] = 'unsupported' },
      ->(candidate) { candidate[:options].first[:discount][:printed_total_stage] = 'unknown' },
      ->(candidate) { candidate[:options].first[:discount][:evidence][:amount][:source_field_path] = 'documents[0].fields.Items[1]' },
      ->(candidate) { candidate[:options].first[:discount][:evidence][:amount][:provider_span_end] = 81 },
      ->(candidate) { candidate[:options].first[:discount][:evidence][:amount] = candidate[:options].first[:evidence][:price] },
      ->(candidate) { candidate[:conflicts] << 'package' },
      ->(candidate) { candidate[:conflicts] = [] },
      ->(candidate) { candidate[:printed_line_total][:amount] = '35' }
    ]

    mutations.each do |mutation|
      context = discount_context
      mutation.call(context[:candidate])

      expect(build_proposals(context)).to be_nil
    end
  end

  it 'rejects changed OCR discount values rather than accepting a checksum over mismatched sources' do
    %i[discount_amount discount_rate original_line_total line_total].each do |field|
      context = discount_context
      context[:item][field] += 1

      expect(build_proposals(context)).to be_nil
    end
  end

  it 'projects the post-discount amount through the public Amount boundary' do
    context = discount_context
    decision = decision_for(context)

    expect(decision).to have_attributes(
      state: 'confirmed',
      selected_pricing_source_kind: 'count_unit_price',
      projected_line_total: 36
    )
  end

  it 'preserves the HALF_UP boundary and an explicitly printed zero discount amount' do
    [
      { price: 49, rate: '0.27', amount: 13, total: 36 },
      { price: 50, rate: '0.27', amount: 14, total: 36 },
      { price: 51, rate: '0.27', amount: 14, total: 37 },
      { price: 1, rate: '0.01', amount: 0, total: 1 }
    ].each do |values|
      decision = decision_for(discount_context(**values))

      expect(decision).to have_attributes(state: 'confirmed', projected_line_total: values[:total])
    end
  end

  it 'rejects a pre-discount amount above the persistence limit even when its post amount fits' do
    expect(decision_for(discount_context, item_line_total_limit: 49)).to have_attributes(
      state: 'unresolved',
      reason: 'source_out_of_bounds'
    )
    expect(decision_for(discount_context, item_line_total_limit: 50)).to have_attributes(state: 'confirmed')
  end

  it 'preserves old explicit-only discount proposals without adding discount authority' do
    context = discount_context
    context[:candidate][:options].shift
    context[:candidate][:options].sole[:source][:line_total_amount] = '50'
    context[:candidate][:printed_line_total][:amount] = '50'
    proposals = build_proposals(context)
    old_snapshot = context[:snapshot].deep_dup
    old_snapshot[:candidates][:items].sole.except!(:discount_amount, :discount_rate)

    expect(proposals).not_to be_nil
    expect(described_class.from_snapshot(proposals, ocr_snapshot: old_snapshot)).to eq(proposals)
    expect(described_class.from_snapshot(proposals, ocr_snapshot: context[:snapshot])).to eq(proposals)
  end

  it 'applies count authority without subtracting the printed discount twice' do
    context = application_context(discount_context)
    original_params = context[:params].deep_dup
    result = apply(context)

    expect(result).to be_applied
    expect(context[:params]).to eq(original_params)
    expect(result.params[:receipt_items_attributes].sole).to include(
      pricing_source_kind: 'count_unit_price',
      original_line_total: 50,
      line_total: 36,
      discount_amount: 14,
      discount_rate: BigDecimal('0.27')
    )
    expect(result.amount_result.dig(:computed, :items).sole).to include(original_line_total: 50, line_total: 36)
    expect(apply(context).params).to eq(result.params)
  end

  it 'does not apply a discounted source after the destination discount or total changes' do
    %i[discount_amount discount_rate original_line_total line_total].each do |field|
      context = application_context(discount_context)
      context[:params][:receipt_items_attributes].sole[field] += 1

      expect(apply(context)).not_to be_applied
    end
  end

  it 'applies an explicitly zero discount without dropping its positive rate source' do
    context = application_context(discount_context(price: 1, rate: '0.01', amount: 0, total: 1))
    result = apply(context)

    expect(result).to be_applied
    expect(result.params[:receipt_items_attributes].sole).to include(
      pricing_source_kind: 'count_unit_price',
      discount_amount: 0,
      discount_rate: BigDecimal('0.01'),
      original_line_total: 1,
      line_total: 1
    )
  end

  it 'rejects a final Amount result with changed discount or pre-discount source' do
    %i[discount_amount discount_rate original_line_total line_total].each do |field|
      context = application_context(discount_context)
      result = apply(context) do |params|
        projected = amount_for(params)
        projected[:computed][:items].sole[field] += 1
        projected
      end

      expect(result).not_to be_applied
    end
  end

  it 'keeps validated discounted authority across the final attribute-normalization boundary' do
    result = apply(application_context(discount_context))
    normalizer = Receipts::Processing::Pipeline::FinalizeStep::AttributeNormalizer
    normalized = normalizer.items(
      result.params[:receipt_items_attributes],
      trusted_item_calculation_mode_sources: result.selections,
      item_price_limit: 999_999,
      item_line_total_limit: 999_999
    )

    expect(normalized.sole).to include(
      pricing_source_kind: 'count_unit_price',
      original_line_total: 50,
      line_total: 36,
      discount_amount: 14,
      discount_rate: BigDecimal('0.27')
    )
  end

  it 'rejects changed, partial and over-bound discount tuples at final attribute normalization' do
    result = apply(application_context(discount_context))
    normalizer = Receipts::Processing::Pipeline::FinalizeStep::AttributeNormalizer
    mutations = [
      { discount_amount: 13 },
      { discount_rate: BigDecimal('0.28') },
      { discount_rate: nil },
      { discount_amount: nil },
      { original_line_total: 51 },
      { line_total: 35 }
    ]

    mutations.each do |mutation|
      items = result.params[:receipt_items_attributes].deep_dup
      items.sole.merge!(mutation)
      normalized = normalizer.items(
        items,
        trusted_item_calculation_mode_sources: result.selections,
        item_price_limit: 999_999,
        item_line_total_limit: 999_999
      )

      expect(normalized.sole[:pricing_source_kind]).to be_nil
    end

    normalized = normalizer.items(
      result.params[:receipt_items_attributes],
      trusted_item_calculation_mode_sources: result.selections,
      item_price_limit: 999_999,
      item_line_total_limit: 49
    )

    expect(normalized.sole[:pricing_source_kind]).to be_nil
  end

  [
    { price: 50, rate: '0.27', amount: 14, total: 36 },
    { price: 1, rate: '0.01', amount: 0, total: 1 }
  ].each do |values|
    it "persists and retries an explicit discount of #{values[:amount]} through the public finalize workflow" do
      context = discount_context(**values)
      ocr_result = {
        success: true,
        lines: [],
        candidates: context[:snapshot][:candidates].merge(
          country_region: 'JPN',
          item_calculation_mode_candidates: [ context[:candidate] ]
        )
      }
      receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
      run = Receipts::Processing.start(receipt: receipt, source: 'upload').run
      Receipts::Processing.record_ocr_snapshot(run, ocr_result)
      Receipts::Processing.record_finalize_decision(
        run,
        Receipts::Processing::Contracts::FinalizeDecision.new(
          finalize_strategy: 'ocr_only',
          error_code: nil,
          error_message: nil,
          receipt_attributes: {},
          ocr_result: nil,
          ai_result: nil,
          metadata: {}
        )
      )

      Receipts::Processing.run_finalize(run)
      item = receipt.reload.receipt_items.sole

      expect(item).to have_attributes(
        pricing_source_kind: 'count_unit_price',
        original_line_total: values[:price],
        line_total: values[:total],
        discount_amount: values[:amount],
        discount_rate: BigDecimal(values[:rate])
      )

      before_retry = item.attributes
      Receipts::Processing.run_finalize(run.reload)

      expect(receipt.reload.receipt_items.sole.attributes).to eq(before_retry)
    ensure
      receipt&.image&.purge
    end
  end
end
