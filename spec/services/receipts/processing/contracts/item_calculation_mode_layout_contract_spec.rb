require 'rails_helper'

RSpec.describe Receipts::Processing::Contracts::ItemCalculationModeProposalSet do
  def line_evidence(line_index, span_start, span_end)
    {
      source_field_path: "pages[0].lines[#{line_index}]",
      provider_span_start: span_start,
      provider_span_end: span_end
    }
  end

  def calculation_layout_context(mode)
    identity = 'azure_calculation_layout_p0_name_l0_s0_e3_block_e100'
    reference = mode == 'reference_quantity_price'
    explicit = mode == 'explicit_line_total'
    total = reference ? 5 : 100
    total_evidence = line_evidence(explicit ? 1 : 3, 80, 83)
    source = if reference
      {
        reference_price_amount: '2',
        reference_quantity: '100',
        reference_quantity_unit_code: 'gram',
        reference_quantity_origin: 'explicit',
        purchased_quantity: '250',
        purchased_quantity_unit_code: 'gram',
        reference_price_tax_inclusion: 'gross'
      }
    else
      { price_amount: '50', quantity: '2', quantity_unit_code: 'piece' }
    end
    evidence = if reference
      {
        reference_price: line_evidence(1, 20, 21),
        reference_quantity: line_evidence(1, 23, 26),
        reference_unit: line_evidence(1, 26, 27),
        tax_inclusion: line_evidence(1, 30, 32),
        purchased_quantity: line_evidence(2, 50, 53),
        purchased_unit: line_evidence(2, 53, 54)
      }
    else
      {
        price: line_evidence(1, 20, 22),
        quantity: line_evidence(2, 50, 51),
        quantity_unit: line_evidence(2, 51, 52)
      }
    end
    options = []
    unless explicit
      options << {
        proposal_id: "#{identity}_#{mode}",
        pricing_source_kind: mode,
        source: source,
        evidence: evidence
      }
    end
    options << {
      proposal_id: "#{identity}_explicit_line_total",
      pricing_source_kind: 'explicit_line_total',
      source: { line_total_amount: total.to_s },
      evidence: { line_total: total_evidence }
    }
    candidate = {
      candidate_id: "#{identity}_item_calculation_mode",
      item_identity: identity,
      item_index: 0,
      source_provider: 'azure_calculation_layout',
      provider_model_id: 'prebuilt-receipt',
      provider_api_version: '2024-11-30',
      string_index_type: 'textElements',
      source_field_path: 'pages[0].lines[0]',
      provider_span_start: 0,
      provider_span_end: 100,
      destination_evidence: line_evidence(0, 0, 3),
      printed_line_total: { amount: total.to_s, evidence: total_evidence },
      conflicts: [],
      options: options
    }
    item = {
      raw_text: '検証品',
      ocr_item_identity: identity,
      price: explicit ? nil : (reference ? 2 : 50),
      quantity: reference ? 250 : 2,
      quantity_unit_code: reference ? 'gram' : 'piece',
      original_line_total: total,
      line_total: total,
      position_index: 0
    }
    result = {
      success: true,
      lines: [],
      candidates: {
        items: [ item ],
        reference_pricing_candidates: [],
        item_calculation_mode_candidates: [ candidate ]
      }
    }
    snapshot = {
      schema_version: described_class::OCR_RESULT_SCHEMA_VERSION,
      success: true,
      candidates: result[:candidates],
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

    { result: result, snapshot: snapshot, candidate: candidate, item: item }
  end

  %w[count_unit_price reference_quantity_price explicit_line_total].each do |mode|
    it "round-trips first-class layout #{mode} without inventing an Azure Item index" do
      context = calculation_layout_context(mode)
      proposals = described_class.build_all(candidates: [ context[:candidate] ], ocr_snapshot: context[:snapshot])

      expect(proposals).not_to be_nil
      expect(proposals.sole['source_field_path']).to eq('pages[0].lines[0]')
      expect(proposals.sole['options'].first['pricing_source_kind']).to eq(mode)
      expect(described_class.from_snapshot(JSON.parse(JSON.generate(proposals)), ocr_snapshot: context[:snapshot])).to eq(proposals)
      snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(context[:result])
      expect(snapshot.dig('candidates', 'items').sole['ocr_item_identity']).to eq(context[:item][:ocr_item_identity])
      expect(snapshot.dig('adoption_proposals', 'item_calculation_modes').size).to eq(1)
    end
  end

  it 'round-trips disjoint name and explicit total evidence on the same provider line' do
    context = calculation_layout_context('explicit_line_total')
    candidate = context[:candidate]
    candidate[:options].sole[:evidence][:line_total][:source_field_path] = 'pages[0].lines[0]'
    candidate[:printed_line_total][:evidence][:source_field_path] = 'pages[0].lines[0]'

    proposals = described_class.build_all(candidates: [ candidate ], ocr_snapshot: context[:snapshot])

    expect(proposals).not_to be_nil
    expect(described_class.from_snapshot(proposals, ocr_snapshot: context[:snapshot])).to eq(proposals)
  end

  it 'rejects same-line totals that overlap the destination or precede its end' do
    [ [ 0, 2 ], [ 2, 4 ] ].each do |span_start, span_end|
      context = calculation_layout_context('explicit_line_total')
      candidate = context[:candidate]
      evidence = line_evidence(0, span_start, span_end)
      candidate[:options].sole[:evidence][:line_total] = evidence
      candidate[:printed_line_total][:evidence] = evidence

      expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: context[:snapshot])).to be_nil
    end
  end

  it 'rejects foreign paths, role changes, overlaps, unsupported sources and mismatched structural identities' do
    mutations = [
      ->(candidate) { candidate[:source_provider] = 'unknown_layout' },
      ->(candidate) { candidate[:item_identity] += '_other' },
      ->(candidate) { candidate[:options].first[:proposal_id] += '_other' },
      ->(candidate) { candidate[:options].first[:evidence][:price][:source_field_path] = 'documents[0].fields.Items[0].Price' },
      ->(candidate) { candidate[:options].first[:evidence][:quantity][:source_field_path] = 'pages[0].lines[1]' },
      ->(candidate) { candidate[:options].first[:evidence][:quantity][:provider_span_end] = 101 },
      ->(candidate) { candidate[:options].first[:evidence][:quantity_unit] = candidate[:options].first[:evidence][:quantity] },
      ->(candidate) { candidate[:options].first[:source][:quantity] = '2.5' },
      ->(candidate) { candidate[:conflicts] = [ 'package' ] }
    ]

    mutations.each do |mutation|
      context = calculation_layout_context('count_unit_price')
      mutation.call(context[:candidate])

      expect(described_class.build_all(candidates: [ context[:candidate] ], ocr_snapshot: context[:snapshot])).to be_nil
    end
  end

  it 'round-trips the complete separate-label count tuple without changing its exact sources' do
    context = calculation_layout_context('count_unit_price')
    candidate = context[:candidate]
    count = candidate[:options].first
    count[:evidence][:price][:source_field_path] = 'pages[0].lines[2]'
    count[:evidence][:quantity][:source_field_path] = 'pages[0].lines[4]'
    count[:evidence][:quantity_unit][:source_field_path] = 'pages[0].lines[4]'
    candidate[:options].last[:evidence][:line_total][:source_field_path] = 'pages[0].lines[5]'
    source = count[:source].deep_dup

    proposals = described_class.build_all(candidates: [ candidate ], ocr_snapshot: context[:snapshot])

    expect(proposals).not_to be_nil
    expect(proposals.sole['options'].first['source']).to eq(source.stringify_keys)
    expect(described_class.from_snapshot(JSON.parse(JSON.generate(proposals)), ocr_snapshot: context[:snapshot])).to eq(proposals)
  end

  [
    [ 1, 4, 4, 5 ],
    [ 2, 2, 2, 5 ],
    [ 2, 4, 4, 3 ],
    [ 2, 4, 2, 5 ],
    [ 2, 2, 4, 5 ]
  ].each do |tuple|
    it "rejects mixed inline and separate-label evidence paths #{tuple.inspect}" do
      context = calculation_layout_context('count_unit_price')
      candidate = context[:candidate]
      evidence = candidate[:options].first[:evidence]
      evidence[:price][:source_field_path] = "pages[0].lines[#{tuple[0]}]"
      evidence[:quantity][:source_field_path] = "pages[0].lines[#{tuple[1]}]"
      evidence[:quantity_unit][:source_field_path] = "pages[0].lines[#{tuple[2]}]"
      candidate[:options].last[:evidence][:line_total][:source_field_path] = "pages[0].lines[#{tuple[3]}]"

      expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: context[:snapshot])).to be_nil
    end
  end

  it 'does not expand reference evidence into the separate-label count grammar' do
    context = calculation_layout_context('reference_quantity_price')
    evidence = context[:candidate][:options].first[:evidence]
    %i[reference_price reference_quantity reference_unit tax_inclusion].each do |role|
      evidence[role][:source_field_path] = 'pages[0].lines[2]'
    end
    %i[purchased_quantity purchased_unit].each do |role|
      evidence[role][:source_field_path] = 'pages[0].lines[4]'
    end
    context[:candidate][:options].last[:evidence][:line_total][:source_field_path] = 'pages[0].lines[5]'

    expect(described_class.build_all(candidates: [ context[:candidate] ], ocr_snapshot: context[:snapshot])).to be_nil
  end

  it 'rejects a price span after the quantity line despite an earlier price path' do
    context = calculation_layout_context('count_unit_price')
    context[:candidate][:options].first[:evidence][:price] = line_evidence(1, 60, 62)

    expect(described_class.build_all(candidates: [ context[:candidate] ], ocr_snapshot: context[:snapshot])).to be_nil
  end

  it 'rejects a purchased unit before its quantity within the same line' do
    context = calculation_layout_context('count_unit_price')
    context[:candidate][:options].first[:evidence][:quantity_unit] = line_evidence(2, 48, 49)

    expect(described_class.build_all(candidates: [ context[:candidate] ], ocr_snapshot: context[:snapshot])).to be_nil
  end

  it 'rejects a printed total span before the price despite a later total path' do
    context = calculation_layout_context('count_unit_price')
    total_evidence = line_evidence(3, 10, 13)
    context[:candidate][:options].last[:evidence][:line_total] = total_evidence
    context[:candidate][:printed_line_total][:evidence] = total_evidence

    expect(described_class.build_all(candidates: [ context[:candidate] ], ocr_snapshot: context[:snapshot])).to be_nil
  end

  [ true, false ].each do |overlapping|
    it "#{overlapping ? 'rejects overlapping' : 'accepts disjoint'} layout blocks with distinct identities" do
      context = calculation_layout_context('count_unit_price')
      second = calculation_layout_context('count_unit_price')
      identity = if overlapping
        'azure_calculation_layout_p0_name_l0_s0_e4_block_e100'
      else
        'azure_calculation_layout_p0_name_l4_s100_e103_block_e200'
      end
      candidate = second[:candidate]
      candidate[:item_identity] = identity
      candidate[:candidate_id] = "#{identity}_item_calculation_mode"
      candidate[:item_index] = 1
      candidate[:options].each do |option|
        option[:proposal_id] = "#{identity}_#{option[:pricing_source_kind]}"
      end
      second[:item].merge!(ocr_item_identity: identity, position_index: 1)
      if overlapping
        candidate[:destination_evidence][:provider_span_end] = 4
      else
        candidate[:source_field_path] = 'pages[0].lines[4]'
        candidate[:provider_span_start] += 100
        candidate[:provider_span_end] += 100
        evidence = [ candidate[:destination_evidence] ] + candidate[:options].flat_map { |option| option[:evidence].values }
        evidence.each do |component|
          index = component[:source_field_path][/\d+(?=\]\z)/].to_i
          component[:source_field_path] = "pages[0].lines[#{index + 4}]"
          component[:provider_span_start] += 100
          component[:provider_span_end] += 100
        end
      end
      context[:snapshot][:candidates][:items] << second[:item]
      context[:snapshot][:candidates][:item_calculation_mode_candidates] << candidate
      %i[items item_calculation_mode_candidates].each do |key|
        context[:snapshot][:candidate_counts][key] = { actual_count: 2, snapshot_count: 2 }
      end

      proposals = described_class.build_all(
        candidates: context[:snapshot][:candidates][:item_calculation_mode_candidates],
        ocr_snapshot: context[:snapshot]
      )

      if overlapping
        expect(proposals).to be_nil
      else
        expect(proposals.size).to eq(2)
      end
    end
  end

  it 'rejects reference source incompleteness, incompatible units and unknown evidence roles' do
    mutations = [
      ->(option) { option[:source].delete(:reference_quantity_origin) },
      ->(option) { option[:source][:purchased_quantity_unit_code] = 'milliliter' },
      ->(option) { option[:source][:reference_price_tax_inclusion] = 'unknown' },
      ->(option) { option[:evidence][:unknown] = option[:evidence][:reference_unit] },
      ->(option) { option[:evidence][:reference_unit][:source_field_path] = 'pages[0].lines[2]' },
      ->(option) { option[:evidence][:reference_unit] = line_evidence(1, 22, 23) },
      ->(option) { option[:evidence][:purchased_unit] = line_evidence(2, 48, 49) }
    ]

    mutations.each do |mutation|
      context = calculation_layout_context('reference_quantity_price')
      mutation.call(context[:candidate][:options].first)

      expect(described_class.build_all(candidates: [ context[:candidate] ], ocr_snapshot: context[:snapshot])).to be_nil
    end
  end

  it 'preserves an unresolved layout item without creating an authority proposal' do
    context = calculation_layout_context('explicit_line_total')
    context[:result][:candidates][:item_calculation_mode_candidates] = []
    context[:item].merge!(price: nil, line_total: nil, original_line_total: nil)
    snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(context[:result])

    expect(snapshot.dig('candidates', 'items').size).to eq(1)
    expect(snapshot.dig('candidates', 'items').sole['ocr_item_identity']).to eq(context[:item][:ocr_item_identity])
    expect(snapshot.dig('adoption_proposals', 'item_calculation_modes')).to be_nil
  end

  it 'retains the first-class layout identity at trusted count normalization' do
    context = calculation_layout_context('count_unit_price')
    selection = Receipts::Processing::Pipeline::FinalizeStep::ItemCalculationModeApplicator::Selection.new(
      item_identity: context[:item][:ocr_item_identity],
      item_index: 0,
      position_index: 0,
      proposal_id: context[:candidate][:options].first[:proposal_id],
      pricing_source_kind: 'count_unit_price',
      price: 50,
      quantity: BigDecimal('2'),
      quantity_unit_code: 'piece',
      projected_line_total: 100
    )
    item = context[:item].merge(pricing_source_kind: 'count_unit_price', quantity: BigDecimal('2'))
    normalized = Receipts::Processing::Pipeline::FinalizeStep::AttributeNormalizer.items(
      [ item ],
      trusted_item_calculation_mode_sources: [ selection ],
      item_price_limit: 999_999,
      item_line_total_limit: 999_999
    )

    expect(normalized.sole[:pricing_source_kind]).to eq('count_unit_price')
  end
end
