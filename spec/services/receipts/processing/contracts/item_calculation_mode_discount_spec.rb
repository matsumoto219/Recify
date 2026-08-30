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

  def decision_for(context, item_line_total_limit: 999_999)
    Receipts::Processing::Contracts::ItemCalculationModeDecision.call(
      item_identity: context[:item][:ocr_item_identity],
      item_proposals: build_proposals(context),
      ocr_snapshot: context[:snapshot],
      count_tax_semantics: 'reproducible_as_recorded',
      item_price_limit: 999_999,
      item_line_total_limit: item_line_total_limit
    )
  end

  def amount_for(params)
    ReceiptAmountService.call(
      receipt: params[:receipt_attributes],
      receipt_items: params[:receipt_items_attributes],
      receipt_tax_details: params[:receipt_tax_details_attributes],
      receipt_adjustments: [],
      receipt_payments: [],
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
