require 'rails_helper'

RSpec.describe Receipts::Processing::Contracts::ItemCalculationModeProposalSet do
  def parsed_ocr_result
    raw = JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def parsed_ocr_result_without_totals
    raw = JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)
    raw.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray').each do |item|
      item.fetch('valueObject').delete('TotalPrice')
    end

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def parsed_structured_reference_result(
    with_total: true,
    string_index_type: 'utf16CodeUnit',
    item_scoped_tax_evidence: false
  )
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_item_calculation_reference_gross_anonymized.json').read
    )
    raw.dig('analyzeResult')['stringIndexType'] = string_index_type
    if item_scoped_tax_evidence
      price = raw.dig(
        'analyzeResult',
        'documents',
        0,
        'fields',
        'Items',
        'valueArray',
        0,
        'valueObject',
        'Price'
      )
      price['content'] = '¥498/100g'
      price.fetch('spans').sole.replace('offset' => 7, 'length' => 9)
    end
    unless with_total
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
    end

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def parsed_structured_inner_tax_reference_result(implicit_per_unit: false)
    result = parsed_structured_reference_result.deep_dup
    result.dig(:candidates).merge!(total_amount: 1703, tax_amount: 154)
    reference = result.dig(:candidates, :reference_pricing_candidates).sole
    reference[:tax_inclusion_evidence] = single_structured_item_gross_evidence
    return result unless implicit_per_unit

    result.dig(:candidates).merge!(total_amount: 600, tax_amount: 54)
    result.dig(:candidates, :items, 0).merge!(
      price: 2,
      quantity: 300,
      line_total: 600,
      original_line_total: 600
    )
    mode_candidate = result.dig(:candidates, :item_calculation_mode_candidates).sole
    mode_candidate[:printed_line_total][:amount] = '600'
    mode_candidate.dig(:options, 0, :source)[:line_total_amount] = '600'
    reference[:reference_price][:amount] = '2'
    reference[:reference_quantity].merge!(
      amount: '1',
      origin: 'implicit_per_unit',
      evidence: {
        source_provider: 'azure_structured',
        source_field_path: 'documents[0].fields.Items[0].QuantityUnit',
        item_index: 0,
        provider_span_start: 20,
        provider_span_end: 21
      }
    )
    reference[:purchased_quantity].merge!(amount: '300')
    reference[:purchased_quantity][:evidence].merge!(provider_span_end: 20)
    reference[:printed_line_total][:amount] = '600'
    reference[:corroboration] = {
      exact_amount: { numerator: '600', denominator: '1' },
      projected_amount: 600,
      printed_line_total: '600',
      rounding_matches: %w[floor half_up ceil]
    }
    reference[:tax_inclusion_evidence] = single_structured_item_gross_evidence(
      amount: 600,
      tax_amount: 54
    )
    result
  end

  def item_layout_candidate(amount: '1703', span_offset: 0)
    name_start = span_offset + 6
    name_end = span_offset + 12
    total_start = span_offset + 34
    total_end = span_offset + 40
    candidate_id = 'azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l4'
    item_identity =
      "azure_item_layout_item_p0_name_l1_s#{name_start}_e#{name_end}_ref_l2_qty_l3_total_l4"
    destination_evidence = {
      source_provider: 'azure_item_layout',
      source_field_path: 'pages[0].lines[1]',
      page_index: 0,
      line_index: 1,
      string_index_type: 'textElements',
      provider_span_start: name_start,
      provider_span_end: name_end,
      word_spans: [
        {
          source_field_path: 'pages[0].words[1]',
          word_index: 1,
          provider_span_start: name_start,
          provider_span_end: name_end
        }
      ]
    }
    total_evidence = {
      source_provider: 'azure_item_layout',
      source_field_path: 'pages[0].lines[4]',
      page_index: 0,
      line_index: 4,
      string_index_type: 'textElements',
      provider_span_start: total_start,
      provider_span_end: total_end
    }

    {
      candidate_id: "#{candidate_id}_item_calculation_mode",
      item_identity: item_identity,
      item_index: 0,
      source_provider: 'azure_item_layout',
      destination_kind: 'azure_layout_item',
      provider_model_id: 'prebuilt-receipt',
      provider_api_version: '2024-11-30',
      string_index_type: 'textElements',
      source_field_path: 'pages[0].lines[1]',
      provider_span_start: name_start,
      provider_span_end: span_offset + 45,
      destination_evidence: destination_evidence,
      owned_line_indexes: [ 1, 2, 3, 4 ],
      printed_line_total: {
        amount: amount,
        evidence: total_evidence
      },
      conflicts: [],
      options: [
        {
          proposal_id: "#{candidate_id}_explicit_line_total",
          pricing_source_kind: 'explicit_line_total',
          source: { line_total_amount: amount },
          evidence: { line_total: total_evidence.deep_dup }
        }
      ]
    }
  end

  def item_layout_snapshot(candidate)
    amount = candidate.dig(:printed_line_total, :amount)
    {
      schema_version: Receipts::Processing::Runs::SnapshotBuilder::OCR_RESULT_SCHEMA_VERSION,
      success: true,
      candidates: {
        items: [
          {
            price: '498',
            quantity: '342',
            quantity_unit_code: 'gram',
            line_total: amount.to_i,
            original_line_total: amount.to_i,
            ocr_item_identity: candidate.fetch(:item_identity)
          }
        ],
        reference_pricing_candidates: [
          {
            candidate_id: candidate.fetch(:candidate_id).sub(/_item_calculation_mode\z/, '_reference_pricing'),
            item_index: 0,
            validation_state: 'valid',
            rejection_reasons: []
          }
        ]
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
  end

  def single_item_gross_summary_evidence(
    amount: 1703,
    tax_amount: 154,
    net_amount: 1549,
    rate: '0.1',
    summary_span: 46...55,
    tax_span: 56...76
  )
    {
      kind: 'single_item_receipt_gross_summary',
      string_index_type: 'textElements',
      policy_contract_version: 'reference_pricing_single_item_gross_summary_policy_v1',
      summary_total: {
        source_provider: 'azure_item_layout',
        source_field_path: 'pages[0].lines[5]',
        page_index: 0,
        line_index: 5,
        string_index_type: 'textElements',
        provider_span_start: summary_span.begin,
        provider_span_end: summary_span.end,
        amount: amount
      },
      gross_tax_target: {
        source_provider: 'azure_item_layout',
        source_field_path: 'pages[0].lines[6]',
        page_index: 0,
        line_index: 6,
        string_index_type: 'textElements',
        provider_span_start: tax_span.begin,
        provider_span_end: tax_span.end,
        rate: rate,
        net_amount: net_amount,
        tax_amount: tax_amount,
        gross_amount: amount
      }
    }
  end

  def single_structured_item_gross_evidence(amount: 1703, tax_amount: 154)
    line = lambda do |path, line_index, span, source_provider: 'azure_structured'|
      {
        source_provider: source_provider,
        source_field_path: path,
        page_index: 0,
        line_index: line_index,
        string_index_type: 'utf16CodeUnit',
        provider_span_start: span.begin,
        provider_span_end: span.end
      }
    end

    {
      kind: 'single_item_receipt_inner_tax_summary',
      string_index_type: 'utf16CodeUnit',
      policy_contract_version: 'reference_pricing_single_structured_item_gross_policy_v1',
      item_parent: {
        source_provider: 'azure_structured',
        source_field_path: 'documents[0].fields.Items[0]',
        item_index: 0,
        provider_span_start: 0,
        provider_span_end: 28
      },
      tax_detail_parent: {
        source_provider: 'azure_structured',
        source_field_path: 'documents[0].fields.TaxDetails[0]',
        tax_detail_index: 0,
        provider_span_start: 30,
        provider_span_end: 42
      },
      tax_description: line.call(
        'documents[0].fields.TaxDetails[0].Description', 4, 30...35
      ).merge(tax_detail_index: 0),
      tax_amount: line.call(
        'documents[0].fields.TaxDetails[0].Amount', 5, 36...39
      ).merge(tax_detail_index: 0, amount: tax_amount),
      document_tax_total: line.call(
        'documents[0].fields.TotalTax', 5, 36...39
      ).merge(amount: tax_amount),
      summary_total: line.call(
        'pages[0].lines[7]', 7, 44...49, source_provider: 'azure_document_total'
      ).merge(amount: amount)
    }
  end

  def hybrid_item_layout_candidate
    candidate = item_layout_candidate
    candidate.merge(
      item_identity: 'azure_structured_item_i0_s0_e22',
      destination_kind: 'azure_structured_item'
    )
  end

  def hybrid_item_layout_snapshot(candidate = hybrid_item_layout_candidate)
    snapshot = item_layout_snapshot(candidate)
    snapshot[:candidates].merge!(total_amount: 1703, tax_amount: 154)
    snapshot.dig(:candidates, :reference_pricing_candidates).sole.merge!(
      source_kind: 'azure_item_layout',
      item_identity: candidate.fetch(:item_identity),
      destination_kind: 'azure_structured_item',
      structured_item_index: 0,
      page_index: 0,
      name_line_index: 1,
      reference_line_index: 2,
      reference_line_provider_span_start: 13,
      reference_line_provider_span_end: 23,
      purchased_quantity_line_indexes: [ 3 ],
      printed_total_line_index: 4,
      owned_line_indexes: [ 1, 2, 3, 4 ],
      string_index_type: 'textElements',
      provider_model_id: 'prebuilt-receipt',
      provider_api_version: '2024-11-30',
      validation_contract_version: 'azure_item_layout_v1',
      block_provider_span_start: 6,
      block_provider_span_end: 45,
      reference_price: {
        amount: '498',
        evidence: {
          source_provider: 'azure_item_layout',
          source_field_path: 'pages[0].lines[2]',
          page_index: 0,
          line_index: 2,
          string_index_type: 'textElements',
          provider_span_start: 14,
          provider_span_end: 17
        }
      },
      reference_quantity: {
        amount: '100',
        unit_code: 'gram',
        unit_status: 'known',
        origin: 'explicit',
        evidence: {
          source_provider: 'azure_item_layout',
          source_field_path: 'pages[0].lines[2]',
          page_index: 0,
          line_index: 2,
          string_index_type: 'textElements',
          provider_span_start: 19,
          provider_span_end: 22
        }
      },
      purchased_quantity: {
        amount: '342',
        unit_code: 'gram',
        unit_status: 'known',
        evidence: {
          source_provider: 'azure_item_layout',
          source_field_path: 'pages[0].lines[3]',
          page_index: 0,
          line_index: 3,
          string_index_type: 'textElements',
          provider_span_start: 25,
          provider_span_end: 28
        }
      },
      reference_price_tax_inclusion: 'gross',
      tax_inclusion_evidence: single_item_gross_summary_evidence,
      printed_line_total: candidate.fetch(:printed_line_total).deep_dup,
      corroboration: {
        exact_amount: { numerator: '42579', denominator: '25' },
        projected_amount: 1703,
        printed_line_total: '1703',
        rounding_matches: %w[floor half_up]
      }
    )
    snapshot
  end

  def column_header_hybrid_case
    candidate = hybrid_item_layout_candidate.deep_dup
    candidate[:candidate_id] = candidate[:candidate_id].sub('name_l1', 'name_l0')
    candidate[:source_field_path] = 'pages[0].lines[0]'
    candidate[:owned_line_indexes] = [ 0, 1, 2, 3, 4 ]
    candidate[:destination_evidence].merge!(source_field_path: 'pages[0].lines[0]', line_index: 0)
    candidate.dig(:options, 0)[:proposal_id] = candidate[:candidate_id].sub(
      /_item_calculation_mode\z/,
      '_explicit_line_total'
    )

    snapshot = hybrid_item_layout_snapshot(candidate)
    reference = snapshot.dig(:candidates, :reference_pricing_candidates).sole
    reference[:name_line_index] = 0
    reference[:owned_line_indexes] = candidate[:owned_line_indexes]
    reference.merge!(reference_line_provider_span_start: 18, reference_line_provider_span_end: 23)
    reference.dig(:reference_price, :evidence).merge!(provider_span_start: 19, provider_span_end: 22)
    reference.dig(:reference_quantity, :evidence).merge!(
      source_field_path: 'pages[0].lines[1]',
      line_index: 1,
      provider_span_start: 14,
      provider_span_end: 17
    )
    [ candidate, snapshot ]
  end

  def quantity_before_reference_hybrid_case
    candidate = hybrid_item_layout_candidate.deep_dup
    candidate_prefix = 'azure_item_layout_p0_name_l0_ref_l2_qty_l1_total_l3'
    candidate.merge!(
      candidate_id: "#{candidate_prefix}_item_calculation_mode",
      source_field_path: 'pages[0].lines[0]',
      owned_line_indexes: [ 0, 1, 2, 3 ]
    )
    candidate[:destination_evidence].merge!(source_field_path: 'pages[0].lines[0]', line_index: 0)
    candidate[:printed_line_total][:evidence].merge!(
      source_field_path: 'pages[0].lines[3]',
      line_index: 3,
      provider_span_start: 34,
      provider_span_end: 40
    )
    candidate.dig(:options, 0).merge!(proposal_id: "#{candidate_prefix}_explicit_line_total")
    candidate.dig(:options, 0, :evidence, :line_total).replace(
      candidate.dig(:printed_line_total, :evidence).deep_dup
    )

    snapshot = hybrid_item_layout_snapshot(candidate)
    reference = snapshot.dig(:candidates, :reference_pricing_candidates).sole
    reference.merge!(
      name_line_index: 0,
      reference_line_index: 2,
      reference_line_provider_span_start: 20,
      reference_line_provider_span_end: 30,
      purchased_quantity_line_indexes: [ 1 ],
      printed_total_line_index: 3,
      owned_line_indexes: [ 0, 1, 2, 3 ]
    )
    reference.dig(:reference_price, :evidence).merge!(
      source_field_path: 'pages[0].lines[2]',
      line_index: 2,
      provider_span_start: 21,
      provider_span_end: 24
    )
    reference.dig(:reference_quantity, :evidence).merge!(
      source_field_path: 'pages[0].lines[2]',
      line_index: 2,
      provider_span_start: 26,
      provider_span_end: 29
    )
    reference.dig(:purchased_quantity, :evidence).merge!(
      source_field_path: 'pages[0].lines[1]',
      line_index: 1,
      provider_span_start: 14,
      provider_span_end: 18
    )
    reference[:printed_line_total][:evidence].replace(candidate.dig(:printed_line_total, :evidence).deep_dup)
    [ candidate, snapshot ]
  end

  def snapshot_without_proposals(result)
    result = result.deep_dup
    result[:candidates] = result.fetch(:candidates).deep_dup

    builder = Receipts::Processing::Runs::SnapshotBuilder.new
    candidates = builder.send(
      :ocr_candidates_snapshot,
      result.fetch(:candidates).deep_symbolize_keys,
      lines: Array(result[:lines]),
      source_lines: Array(result[:lines])
    )
    candidate_counts = builder.send(
      :ocr_candidate_counts,
      result.fetch(:candidates).deep_symbolize_keys,
      candidates
    )
    {
      schema_version: Receipts::Processing::Runs::SnapshotBuilder::OCR_RESULT_SCHEMA_VERSION,
      success: true,
      candidates: candidates,
      candidate_counts: candidate_counts,
      truncated: {
        items: false,
        reference_pricing_candidates: false,
        item_calculation_mode_candidates: false
      }
    }
  end

  def recompute_integrity!(proposal, snapshot:)
    context = described_class.send(:ocr_context, snapshot)
    proposal['integrity_checksum'] = described_class.send(:integrity_checksum, proposal, context:)
    proposal
  end

  describe '.build_all' do
    it 'round-trips exact count-unit evidence owned by the same Item parent' do
      result = parsed_ocr_result
      candidates = result.dig(:candidates, :item_calculation_mode_candidates)
      candidates.each do |candidate|
        candidate.dig(:options, 0, :evidence, :quantity_unit)[:source_field_path] = candidate.fetch(:source_field_path)
      end
      snapshot = snapshot_without_proposals(result)

      proposals = described_class.build_all(candidates: candidates, ocr_snapshot: snapshot)

      aggregate_failures do
        expect(proposals&.size).to eq(4)
        expect(described_class.from_snapshot(
          JSON.parse(JSON.generate(proposals)),
          ocr_snapshot: snapshot
        )).to eq(proposals)
      end
    end

    it 'rejects foreign, arbitrary, overlapping, and out-of-parent count-unit evidence' do
      result = parsed_ocr_result
      snapshot = snapshot_without_proposals(result)
      candidate = result.dig(:candidates, :item_calculation_mode_candidates, 0)
      invalid_evidence = [
        { source_field_path: 'documents[0].fields.Items[1]' },
        { source_field_path: 'documents[0].fields.Items[0].Description' },
        { source_field_path: 'pages[0].lines[0]' },
        { source_field_path: candidate[:source_field_path], provider_span_start: candidate[:provider_span_start] - 1 },
        candidate.dig(:options, 0, :evidence, :quantity).merge(source_field_path: candidate[:source_field_path])
      ]

      invalid_evidence.each do |mutation|
        candidates = result.dig(:candidates, :item_calculation_mode_candidates).deep_dup
        candidates.first.dig(:options, 0, :evidence, :quantity_unit).merge!(mutation)

        expect(described_class.build_all(candidates: candidates, ocr_snapshot: snapshot)).to be_nil
      end
    end

    it 'builds bounded exact proposals without raw item text' do
      result = parsed_ocr_result
      snapshot = snapshot_without_proposals(result)

      proposals = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )

      expect(proposals.size).to eq(4)
      expect(proposals).to all(include(
        'schema_version' => 'item_calculation_mode_proposal_set_v1',
        'creation_stage' => 'ocr_validation',
        'source_provider' => 'azure_structured',
        'provider_model_id' => 'prebuilt-receipt',
        'provider_api_version' => '2024-11-30',
        'string_index_type' => 'utf16CodeUnit',
        'integrity_checksum' => match(/\A[0-9a-f]{64}\z/)
      ))
      expect(proposals.first.dig('options', 0, 'source')).to eq(
        'price_amount' => '220',
        'quantity' => '1',
        'quantity_unit_code' => 'item'
      )
      expect(JSON.generate(proposals)).not_to include('ノート A5')
    end

    it 'same-itemのvalid structured referenceをexact optionとしてexplicitと合成する' do
      result = parsed_structured_reference_result
      snapshot = snapshot_without_proposals(result)

      proposal = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      ).sole

      aggregate_failures do
        expect(proposal.fetch('options').map { |option| option.fetch('pricing_source_kind') }).to eq(%w[
          reference_quantity_price
          explicit_line_total
        ])
        expect(proposal.dig('options', 0, 'source_candidate_id')).to eq(
          'azure_items_0_reference_pricing'
        )
        expect(proposal.dig('options', 0, 'source')).to eq(
          'reference_price_amount' => '498',
          'reference_quantity' => '100',
          'reference_quantity_unit_code' => 'gram',
          'reference_quantity_origin' => 'explicit',
          'purchased_quantity' => '342',
          'purchased_quantity_unit_code' => 'gram',
          'reference_price_tax_inclusion' => 'gross'
        )
        expect(JSON.generate(proposal)).not_to include('検証品')
      end
    end

    it 'TotalPriceなしでもsame-itemのvalid structured referenceだけをtyped proposalにする' do
      result = parsed_structured_reference_result(with_total: false)
      snapshot = snapshot_without_proposals(result)

      proposal = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      ).sole

      aggregate_failures do
        expect(proposal.fetch('options').map { |option| option.fetch('pricing_source_kind') }).to eq(
          [ 'reference_quantity_price' ]
        )
        expect(proposal['printed_line_total']).to be_nil
      end
    end

    it 'textElementsのsame-item valid structured referenceもexact optionとして保持する' do
      result = parsed_structured_reference_result(string_index_type: 'textElements')
      snapshot = snapshot_without_proposals(result)

      proposal = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      ).sole

      aggregate_failures do
        expect(proposal['string_index_type']).to eq('textElements')
        expect(proposal.fetch('options').map { |option| option.fetch('pricing_source_kind') }).to eq(%w[
          reference_quantity_price
          explicit_line_total
        ])
        expect(described_class.from_snapshot(
          JSON.parse(JSON.generate([ proposal ])),
          ocr_snapshot: JSON.parse(JSON.generate(snapshot))
        )).to eq([ proposal ])
      end
    end

    it '同一Item parentの税表記で補完したstructured referenceもexact optionとして保持する' do
      result = parsed_structured_reference_result(item_scoped_tax_evidence: true)
      snapshot = snapshot_without_proposals(result)

      proposal = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      ).sole

      aggregate_failures do
        expect(result.dig(
          :candidates,
          :reference_pricing_candidates,
          0,
          :tax_inclusion_evidence,
          :source_field_path
        )).to eq('documents[0].fields.Items[0]')
        expect(proposal.fetch('options').map { |option| option.fetch('pricing_source_kind') }).to eq(%w[
          reference_quantity_price
          explicit_line_total
        ])
      end
    end

    it 'native Item外の内税根拠をreference optionへexactに保持する' do
      result = parsed_structured_inner_tax_reference_result
      snapshot = snapshot_without_proposals(result)

      proposal = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      ).sole
      copied = JSON.parse(JSON.generate([ proposal ]))

      aggregate_failures do
        expect(proposal.fetch('options').pluck('pricing_source_kind')).to eq(%w[
          reference_quantity_price
          explicit_line_total
        ])
        expect(proposal.dig('options', 0, 'evidence', 'tax_inclusion')).to eq(
          snapshot.dig(
            :candidates, :reference_pricing_candidates, 0, :tax_inclusion_evidence
          ).deep_stringify_keys
        )
        expect(described_class.from_snapshot(copied, ocr_snapshot: snapshot)).to eq([ proposal ])
        expect(proposal.to_json).not_to include('raw_text', 'polygon', 'product_name')
      end
    end

    it 'implicit per-unit基準数量1をQuantityUnit evidenceから保持する' do
      result = parsed_structured_inner_tax_reference_result(implicit_per_unit: true)
      snapshot = snapshot_without_proposals(result)

      proposal = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      ).sole
      reference = proposal.fetch('options').find do |option|
        option.fetch('pricing_source_kind') == 'reference_quantity_price'
      end

      aggregate_failures do
        expect(reference.fetch('source')).to include(
          'reference_price_amount' => '2',
          'reference_quantity' => '1',
          'reference_quantity_origin' => 'implicit_per_unit',
          'purchased_quantity' => '300'
        )
        expect(reference.dig('evidence', 'reference_quantity', 'source_field_path')).to eq(
          'documents[0].fields.Items[0].QuantityUnit'
        )
        expect(described_class.from_snapshot(
          JSON.parse(JSON.generate([ proposal ])),
          ocr_snapshot: JSON.parse(JSON.generate(snapshot))
        )).to eq([ proposal ])
      end
    end

    it 'item-layoutの印字明細金額だけをcanonicalなexact proposalとしてround-tripする' do
      candidate = item_layout_candidate
      snapshot = item_layout_snapshot(candidate)

      proposal = described_class.build_all(candidates: [ candidate ], ocr_snapshot: snapshot).sole

      aggregate_failures do
        expect(proposal).to include(
          'source_provider' => 'azure_item_layout',
          'candidate_id' => 'azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l4_item_calculation_mode',
          'item_identity' => 'azure_item_layout_item_p0_name_l1_s6_e12_ref_l2_qty_l3_total_l4',
          'source_field_path' => 'pages[0].lines[1]',
          'destination_evidence' => {
            'source_field_path' => 'pages[0].lines[1]',
            'provider_span_start' => 6,
            'provider_span_end' => 12
          }
        )
        expect(proposal.fetch('options')).to contain_exactly(
          include(
            'proposal_id' => 'azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l4_explicit_line_total',
            'pricing_source_kind' => 'explicit_line_total',
            'source' => { 'line_total_amount' => '1703' },
            'evidence' => {
              'line_total' => {
                'source_field_path' => 'pages[0].lines[4]',
                'provider_span_start' => 34,
                'provider_span_end' => 40
              }
            }
          )
        )
        expect(proposal.to_json).not_to include('word_spans')
        expect(described_class.from_snapshot(
          JSON.parse(JSON.generate([ proposal ])),
          ocr_snapshot: JSON.parse(JSON.generate(snapshot))
        )).to eq([ proposal ])
      end
    end

    it 'structured destinationへ結び付くlayout sourceをreferenceとexplicitのexact proposalへ合成する' do
      candidate = hybrid_item_layout_candidate
      snapshot = hybrid_item_layout_snapshot(candidate)

      proposal = described_class.build_all(candidates: [ candidate ], ocr_snapshot: snapshot).sole

      aggregate_failures do
        expect(proposal).to include(
          'source_provider' => 'azure_item_layout',
          'destination_kind' => 'azure_structured_item',
          'item_identity' => 'azure_structured_item_i0_s0_e22'
        )
        expect(proposal.fetch('options').pluck('pricing_source_kind')).to eq(%w[
          reference_quantity_price
          explicit_line_total
        ])
        expect(proposal.dig('options', 0, 'source_candidate_id')).to eq(
          'azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l4_reference_pricing'
        )
        expect(proposal.dig('options', 0, 'source')).to eq(
          'reference_price_amount' => '498',
          'reference_quantity' => '100',
          'reference_quantity_unit_code' => 'gram',
          'reference_quantity_origin' => 'explicit',
          'purchased_quantity' => '342',
          'purchased_quantity_unit_code' => 'gram',
          'reference_price_tax_inclusion' => 'gross'
        )
        expect(proposal.dig('options', 0, 'evidence', 'tax_inclusion')).to eq(
          single_item_gross_summary_evidence.deep_stringify_keys
        )
        expect(described_class.from_snapshot(
          JSON.parse(JSON.generate([ proposal ])),
          ocr_snapshot: JSON.parse(JSON.generate(snapshot))
        )).to eq([ proposal ])
        expect(proposal.to_json).not_to include('raw_text', 'product_name', 'store_name', 'polygon')
      end
    end

    it 'destination kindをsource providerとidentityの3つの正規組合せだけに限定する' do
      structured_result = parsed_ocr_result
      structured_snapshot = snapshot_without_proposals(structured_result)
      structured_candidates = structured_result.dig(:candidates, :item_calculation_mode_candidates)
      invalid_structured = structured_candidates.deep_dup
      invalid_structured.first[:destination_kind] = 'azure_structured_item'
      layout_candidate = item_layout_candidate
      layout_snapshot = item_layout_snapshot(layout_candidate)
      invalid_layout = layout_candidate.merge(destination_kind: 'azure_structured_item')
      hybrid_candidate = hybrid_item_layout_candidate
      hybrid_snapshot = hybrid_item_layout_snapshot(hybrid_candidate)
      invalid_hybrid = hybrid_candidate.merge(destination_kind: 'azure_layout_item')

      aggregate_failures do
        expect(described_class.build_all(
          candidates: structured_candidates,
          ocr_snapshot: structured_snapshot
        )).to all(satisfy { |proposal| !proposal.key?('destination_kind') })
        expect(described_class.build_all(
          candidates: [ layout_candidate ],
          ocr_snapshot: layout_snapshot
        )).to contain_exactly(include('destination_kind' => 'azure_layout_item'))
        expect(described_class.build_all(
          candidates: [ hybrid_candidate ],
          ocr_snapshot: hybrid_snapshot
        )).to contain_exactly(include('destination_kind' => 'azure_structured_item'))
        expect(described_class.build_all(
          candidates: invalid_structured,
          ocr_snapshot: structured_snapshot
        )).to be_nil
        expect(described_class.build_all(
          candidates: [ invalid_layout ],
          ocr_snapshot: layout_snapshot
        )).to be_nil
        expect(described_class.build_all(
          candidates: [ invalid_hybrid ],
          ocr_snapshot: hybrid_snapshot
        )).to be_nil
      end
    end

    it 'Choice Bをstructured destinationとreceipt summary grossの完全一致へ限定する' do
      candidate = hybrid_item_layout_candidate
      snapshot = hybrid_item_layout_snapshot(candidate)
      layout_only = item_layout_candidate
      layout_only_snapshot = hybrid_item_layout_snapshot(layout_only)
      unknown_evidence = snapshot.deep_dup
      unknown_evidence.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :tax_inclusion_evidence,
        :summary_total
      )[:raw_text] = '保存禁止'
      amount_mismatch = snapshot.deep_dup
      amount_mismatch.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :tax_inclusion_evidence,
        :summary_total
      )[:amount] = 1702
      non_gross = snapshot.deep_dup
      non_gross.dig(:candidates, :reference_pricing_candidates, 0)[:reference_price_tax_inclusion] = 'net'
      overlapping = snapshot.deep_dup
      overlapping.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :tax_inclusion_evidence,
        :summary_total
      ).merge!(provider_span_start: 40, provider_span_end: 44)
      block_line = snapshot.deep_dup
      block_line.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :tax_inclusion_evidence,
        :summary_total
      ).merge!(source_field_path: 'pages[0].lines[4]', line_index: 4)
      structured_parent_overlap_candidate = hybrid_item_layout_candidate.merge(
        item_identity: 'azure_structured_item_i0_s0_e55'
      )
      structured_parent_overlap = hybrid_item_layout_snapshot(structured_parent_overlap_candidate)

      aggregate_failures do
        expect(described_class.build_all(candidates: [ layout_only ], ocr_snapshot: layout_only_snapshot))
          .to contain_exactly(include(
            'options' => [ include('pricing_source_kind' => 'explicit_line_total') ]
          ))
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: unknown_evidence)).to be_nil
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: amount_mismatch)).to be_nil
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: non_gross)).to be_nil
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: overlapping)).to be_nil
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: block_line)).to be_nil
        expect(described_class.build_all(
          candidates: [ structured_parent_overlap_candidate ],
          ocr_snapshot: structured_parent_overlap
        )).to be_nil
      end
    end

    it 'Choice Bのtax算術・receipt context・identity・line境界を改変時にfail closedにする' do
      candidate = hybrid_item_layout_candidate
      snapshot = hybrid_item_layout_snapshot(candidate)
      tax_mismatch = snapshot.deep_dup
      tax_mismatch.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :tax_inclusion_evidence,
        :gross_tax_target
      )[:tax_amount] = 153
      receipt_tax_mismatch = snapshot.deep_dup
      receipt_tax_mismatch.dig(:candidates)[:tax_amount] = 153
      identity_mismatch = snapshot.deep_dup
      identity_mismatch.dig(:candidates, :reference_pricing_candidates, 0)[:item_identity] =
        'azure_structured_item_i0_s0_e44'
      line_over_bound = snapshot.deep_dup
      line_over_bound.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :tax_inclusion_evidence,
        :summary_total
      ).merge!(source_field_path: 'pages[0].lines[150]', line_index: 150)
      line_at_bound = snapshot.deep_dup
      line_at_bound.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :tax_inclusion_evidence,
        :summary_total
      ).merge!(source_field_path: 'pages[0].lines[149]', line_index: 149)
      overprecision_rate = snapshot.deep_dup
      target = overprecision_rate.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :tax_inclusion_evidence,
        :gross_tax_target
      )
      target.merge!(rate: '0.1234567', net_amount: 1516, tax_amount: 187)
      overprecision_rate.dig(:candidates)[:tax_amount] = 187

      aggregate_failures do
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: tax_mismatch)).to be_nil
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: receipt_tax_mismatch)).to be_nil
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: identity_mismatch)).to be_nil
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: line_over_bound)).to be_nil
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: line_at_bound)).to be_present
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: overprecision_rate)).to be_nil
      end
    end

    it 'column producerのreference quantity header pathを保持しpath改変を拒否する' do
      candidate, snapshot = column_header_hybrid_case
      mismatched_path = snapshot.deep_dup
      mismatched_path.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :reference_quantity,
        :evidence
      )[:source_field_path] = 'pages[0].lines[2]'
      outside_owned = snapshot.deep_dup
      outside_owned.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :reference_quantity,
        :evidence
      ).merge!(source_field_path: 'pages[0].lines[5]', line_index: 5)

      aggregate_failures do
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: snapshot)).to be_present
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: mismatched_path)).to be_nil
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: outside_owned)).to be_nil
      end
    end

    it '購入数量がreference priceより前にあるproducer形状をexact tupleとして保持する' do
      candidate, snapshot = quantity_before_reference_hybrid_case

      proposal = described_class.build_all(candidates: [ candidate ], ocr_snapshot: snapshot).sole

      aggregate_failures do
        expect(proposal.fetch('options').pluck('pricing_source_kind')).to eq(%w[
          reference_quantity_price
          explicit_line_total
        ])
        expect(proposal.dig('options', 0, 'evidence', 'purchased_quantity')).to include(
          'source_field_path' => 'pages[0].lines[1]'
        )
        expect(proposal.dig('options', 0, 'evidence', 'reference_price')).to include(
          'source_field_path' => 'pages[0].lines[2]'
        )
      end
    end

    it 'layout producerを既知の5 tupleとexact owned linesだけに限定する' do
      cases = [
        [ 'azure_item_layout_p0_name_l0_ref_l1_qty_l2_total_l3_item_calculation_mode', [ 0, 1, 2, 3 ], [ 2 ], 1 ],
        [ 'azure_item_layout_p0_name_l0_ref_l1_qty_l3_total_l4_item_calculation_mode', [ 0, 1, 2, 3, 4 ], [ 3 ], 1 ],
        [ 'azure_item_layout_p0_name_l0_ref_l1_qty_l3_total_l4_item_calculation_mode', [ 0, 1, 2, 3, 4 ], [ 2, 3 ], 1 ],
        [ 'azure_item_layout_p0_name_l0_ref_l2_qty_l1_total_l3_item_calculation_mode', [ 0, 1, 2, 3 ], [ 1 ], 2 ],
        [ 'azure_item_layout_p0_name_l0_ref_l2_qty_l3_total_l4_item_calculation_mode', [ 0, 1, 2, 3, 4 ], [ 3 ], 1 ]
      ]
      invalid = {
        'candidate_id' => 'azure_item_layout_p0_name_l0_ref_l3_qty_l1_total_l4_item_calculation_mode'
      }

      aggregate_failures do
        cases.each do |candidate_id, owned_line_indexes, purchased_line_indexes, reference_quantity_line_index|
          metadata = described_class.send(:layout_candidate_metadata, { 'candidate_id' => candidate_id })
          reference_candidate = {
            'owned_line_indexes' => owned_line_indexes,
            'purchased_quantity_line_indexes' => purchased_line_indexes,
            'reference_quantity' => {
              'evidence' => { 'source_field_path' => "pages[0].lines[#{reference_quantity_line_index}]" }
            }
          }
          expect(metadata).to be_present
          expect(described_class.send(:exact_owned_line_indexes?, owned_line_indexes, metadata:)).to be(true)
          expect(described_class.send(
            :exact_layout_producer_contract,
            reference_candidate,
            metadata:
          )).to be_present
          expect(described_class.send(
            :exact_owned_line_indexes?,
            owned_line_indexes.drop(1),
            metadata:
          )).to be(false)
        end
        expect(described_class.send(:layout_candidate_metadata, invalid)).to be_nil
      end
    end

    it 'reference line span欠損・component逸脱・reference quantityの別producer pathを拒否する' do
      candidate = hybrid_item_layout_candidate
      snapshot = hybrid_item_layout_snapshot(candidate)
      missing_line_span = snapshot.deep_dup
      missing_line_span.dig(:candidates, :reference_pricing_candidates, 0)
        .delete(:reference_line_provider_span_start)
      price_outside_line = snapshot.deep_dup
      price_outside_line.dig(:candidates, :reference_pricing_candidates, 0)
        .merge!(reference_line_provider_span_start: 15, reference_line_provider_span_end: 23)
      wrong_reference_quantity_line = snapshot.deep_dup
      wrong_reference_quantity_line.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :reference_quantity,
        :evidence
      ).merge!(source_field_path: 'pages[0].lines[1]', line_index: 1)

      aggregate_failures do
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: missing_line_span)).to be_nil
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: price_outside_line)).to be_nil
        expect(described_class.build_all(
          candidates: [ candidate ],
          ocr_snapshot: wrong_reference_quantity_line
        )).to be_nil
      end
    end

    it 'item-layoutへcount/reference optionを混在させず、identity・path・span不一致を部分採用しない' do
      candidate = item_layout_candidate
      snapshot = item_layout_snapshot(candidate)
      count_mixed = candidate.deep_dup
      count_mixed.fetch(:options).prepend(
        proposal_id: 'azure_items_0_count_unit_price',
        pricing_source_kind: 'count_unit_price',
        source: { price_amount: '498', quantity: '342', quantity_unit_code: 'gram' },
        evidence: {}
      )
      mismatched_identity = candidate.deep_dup
      mismatched_identity[:candidate_id] =
        'azure_item_layout_p0_name_l9_ref_l2_qty_l3_total_l4_item_calculation_mode'
      mismatched_path = candidate.deep_dup
      mismatched_path.dig(:printed_line_total, :evidence)[:source_field_path] = 'pages[0].lines[3]'
      mismatched_span = candidate.deep_dup
      mismatched_span[:destination_evidence][:provider_span_end] -= 1

      aggregate_failures do
        expect(described_class.build_all(candidates: [ count_mixed ], ocr_snapshot: snapshot)).to be_nil
        expect(described_class.build_all(candidates: [ mismatched_identity ], ocr_snapshot: snapshot)).to be_nil
        expect(described_class.build_all(candidates: [ mismatched_path ], ocr_snapshot: snapshot)).to be_nil
        expect(described_class.build_all(candidates: [ mismatched_span ], ocr_snapshot: snapshot)).to be_nil
      end
    end

    it 'item-layout optionのunknown fieldをcanonical化で隠さずproposal全体を拒否する' do
      candidate = item_layout_candidate
      snapshot = item_layout_snapshot(candidate)
      option_extra = candidate.deep_dup
      option_extra.dig(:options, 0)[:unknown] = 'discard-me'
      source_extra = candidate.deep_dup
      source_extra.dig(:options, 0, :source)[:unknown] = 'discard-me'
      evidence_extra = candidate.deep_dup
      evidence_extra.dig(:options, 0, :evidence)[:unknown] = 'discard-me'

      aggregate_failures do
        expect(described_class.build_all(candidates: [ option_extra ], ocr_snapshot: snapshot)).to be_nil
        expect(described_class.build_all(candidates: [ source_extra ], ocr_snapshot: snapshot)).to be_nil
        expect(described_class.build_all(candidates: [ evidence_extra ], ocr_snapshot: snapshot)).to be_nil
      end
    end

    it 'item-layoutの明示0円とprovider span上限を受け入れ、上限を1超えるspanは拒否する' do
      zero = item_layout_candidate(amount: '0')
      zero_snapshot = item_layout_snapshot(zero)
      at_limit = item_layout_candidate(
        span_offset: described_class::MAX_PROVIDER_SPAN - 45
      )
      at_limit_snapshot = item_layout_snapshot(at_limit)
      above_limit = item_layout_candidate(
        span_offset: described_class::MAX_PROVIDER_SPAN - 44
      )
      above_limit_snapshot = item_layout_snapshot(above_limit)

      aggregate_failures do
        expect(described_class.build_all(candidates: [ zero ], ocr_snapshot: zero_snapshot))
          .to contain_exactly(include('options' => [ include('source' => { 'line_total_amount' => '0' }) ]))
        expect(described_class.build_all(candidates: [ at_limit ], ocr_snapshot: at_limit_snapshot)).to be_present
        expect(described_class.build_all(candidates: [ above_limit ], ocr_snapshot: above_limit_snapshot)).to be_nil
      end
    end

    it 'item-layout reference candidateの既知26 fieldを受け入れ、専用collection上限超過は拒否する' do
      candidate = item_layout_candidate
      snapshot = item_layout_snapshot(candidate)
      reference = snapshot.dig(:candidates, :reference_pricing_candidates).sole
      reference.merge!(
        source_kind: 'azure_item_layout',
        item_identity: candidate.fetch(:item_identity),
        destination_kind: 'azure_layout_item',
        page_index: 0,
        name_line_index: 1,
        reference_line_index: 2,
        purchased_quantity_line_indexes: [ 3 ],
        printed_total_line_index: 4,
        owned_line_indexes: [ 1, 2, 3, 4 ],
        string_index_type: 'textElements',
        provider_model_id: 'prebuilt-receipt',
        provider_api_version: '2024-11-30',
        validation_contract_version: 'azure_item_layout_v1',
        block_provider_span_start: 6,
        block_provider_span_end: 45,
        reference_price: {},
        reference_quantity: {},
        purchased_quantity: {},
        reference_price_tax_inclusion: 'gross',
        tax_inclusion_evidence: {},
        printed_line_total: {},
        corroboration: {}
      )
      oversized = snapshot.deep_dup
      oversized_reference = oversized.dig(:candidates, :reference_pricing_candidates).sole
      7.times { |index| oversized_reference["unknown_#{index}"] = index }

      aggregate_failures do
        expect(reference.size).to eq(26)
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: snapshot)).to be_present
        expect(described_class.build_all(candidates: [ candidate ], ocr_snapshot: oversized)).to be_nil
      end
    end

    it 'valid optionにunknownまたはkind欠損optionが混在する場合は部分採用しない' do
      result = parsed_ocr_result
      snapshot = snapshot_without_proposals(result)
      candidates = result.dig(:candidates, :item_calculation_mode_candidates)
      unknown = candidates.deep_dup
      unknown.first.fetch(:options) << {
        pricing_source_kind: 'invented',
        source: {},
        evidence: {}
      }
      missing_kind = candidates.deep_dup
      missing_kind.first.fetch(:options) << {
        source: {},
        evidence: {}
      }

      aggregate_failures do
        expect(described_class.build_all(candidates: unknown, ocr_snapshot: snapshot)).to be_nil
        expect(described_class.build_all(candidates: missing_kind, ocr_snapshot: snapshot)).to be_nil
      end
    end

    it 'canonicalizes finite integral provider numbers without losing exact source binding' do
      raw = JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)
      raw.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray').each do |item|
        fields = item.fetch('valueObject')
        fields.dig('Price', 'valueCurrency')['amount'] = fields.dig('Price', 'valueCurrency', 'amount').to_f
        fields.dig('TotalPrice', 'valueCurrency')['amount'] = fields.dig('TotalPrice', 'valueCurrency', 'amount').to_f
        fields['Quantity']['valueNumber'] = fields.dig('Quantity', 'valueNumber').to_f
      end
      result = Ocr::ResponseParser.new(response: raw, provider: :fixture).call
      snapshot = snapshot_without_proposals(result)
      proposals = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )

      aggregate_failures do
        expect(proposals.size).to eq(4)
        expect(described_class.from_snapshot(
          JSON.parse(JSON.generate(proposals)),
          ocr_snapshot: JSON.parse(JSON.generate(snapshot))
        )).to eq(proposals)
      end
    end

    it 'returns no proposal when the OCR item identity is not preserved' do
      result = parsed_ocr_result
      snapshot = snapshot_without_proposals(result)
      snapshot.dig(:candidates, :items, 0).delete(:ocr_item_identity)

      expect(described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )).to be_nil
    end

    it 'rejects overlapping destination and source component evidence before checksumming' do
      result = parsed_ocr_result
      snapshot = snapshot_without_proposals(result)
      candidates = result.dig(:candidates, :item_calculation_mode_candidates).deep_dup
      count = candidates.first.fetch(:options).first
      count[:evidence][:quantity] = count.dig(:evidence, :price).deep_dup

      expect(described_class.build_all(candidates: candidates, ocr_snapshot: snapshot)).to be_nil

      candidates = result.dig(:candidates, :item_calculation_mode_candidates).deep_dup
      candidates.first[:destination_evidence] =
        candidates.first.dig(:options, 0, :evidence, :price).deep_dup

      expect(described_class.build_all(candidates: candidates, ocr_snapshot: snapshot)).to be_nil
    end

    it 'binds by the unique opaque identity when filtered OCR items compress provider indexes' do
      result = parsed_ocr_result
      candidates = result.dig(:candidates, :item_calculation_mode_candidates)
      snapshot = snapshot_without_proposals(result)
      snapshot.dig(:candidates, :items).delete_at(1)
      item_counts = snapshot.dig(:candidate_counts, :items)
      item_counts[:actual_count] -= 1
      item_counts[:snapshot_count] -= 1

      proposals = described_class.build_all(candidates: candidates, ocr_snapshot: snapshot)

      expect(proposals).to be_nil

      remaining_candidates = candidates.reject { |candidate| candidate[:item_index] == 1 }
      proposal_counts = snapshot.dig(:candidate_counts, :item_calculation_mode_candidates)
      proposal_counts[:actual_count] -= 1
      proposal_counts[:snapshot_count] -= 1
      proposals = described_class.build_all(candidates: remaining_candidates, ocr_snapshot: snapshot)

      expect(proposals.map { |proposal| proposal['item_index'] }).to eq([ 0, 2, 3 ])
    end
  end

  describe '.from_snapshot' do
    it 'round-trips exact values and identities' do
      result = parsed_ocr_result
      snapshot = snapshot_without_proposals(result)
      proposals = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )

      expect(described_class.from_snapshot(proposals, ocr_snapshot: snapshot)).to eq(proposals)
    end

    it 'round-trips a count-only proposal without materializing a nil printed total' do
      result = parsed_ocr_result_without_totals
      snapshot = snapshot_without_proposals(result)
      proposals = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )

      aggregate_failures do
        expect(proposals).to all(satisfy { |proposal| !proposal.key?('printed_line_total') })
        expect(described_class.from_snapshot(
          JSON.parse(JSON.generate(proposals)),
          ocr_snapshot: snapshot
        )).to eq(proposals)
      end
    end

    it 'fails closed for an unknown version, checksum mutation, or duplicate identity' do
      result = parsed_ocr_result
      snapshot = snapshot_without_proposals(result)
      proposals = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )

      unknown = proposals.deep_dup
      unknown.first['schema_version'] = 'item_calculation_mode_proposal_set_v2'
      mutated = proposals.deep_dup
      mutated.first.dig('options', 0, 'source')['price_amount'] = '221'
      duplicate = proposals.deep_dup
      duplicate << duplicate.first.deep_dup

      aggregate_failures do
        expect(described_class.from_snapshot(unknown, ocr_snapshot: snapshot)).to be_nil
        expect(described_class.from_snapshot(mutated, ocr_snapshot: snapshot)).to be_nil
        expect(described_class.from_snapshot(duplicate, ocr_snapshot: snapshot)).to be_nil
      end
    end

    it 'destination kind改変をchecksum再計算後もrehydrationで拒否する' do
      structured_result = parsed_ocr_result
      structured_snapshot = snapshot_without_proposals(structured_result)
      structured = described_class.build_all(
        candidates: structured_result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: structured_snapshot
      )
      structured.first['destination_kind'] = 'azure_structured_item'
      recompute_integrity!(structured.first, snapshot: structured_snapshot)

      layout_candidate = item_layout_candidate
      layout_snapshot = item_layout_snapshot(layout_candidate)
      layout = described_class.build_all(candidates: [ layout_candidate ], ocr_snapshot: layout_snapshot)
      layout.sole['destination_kind'] = 'azure_structured_item'
      recompute_integrity!(layout.sole, snapshot: layout_snapshot)

      hybrid_candidate = hybrid_item_layout_candidate
      hybrid_snapshot = hybrid_item_layout_snapshot(hybrid_candidate)
      hybrid = described_class.build_all(candidates: [ hybrid_candidate ], ocr_snapshot: hybrid_snapshot)
      hybrid.sole['destination_kind'] = 'azure_layout_item'
      recompute_integrity!(hybrid.sole, snapshot: hybrid_snapshot)

      aggregate_failures do
        expect(described_class.from_snapshot(structured, ocr_snapshot: structured_snapshot)).to be_nil
        expect(described_class.from_snapshot(layout, ocr_snapshot: layout_snapshot)).to be_nil
        expect(described_class.from_snapshot(hybrid, ocr_snapshot: hybrid_snapshot)).to be_nil
      end
    end

    it 'rejects a proposal when the bound OCR item exact source changes without an identity change' do
      result = parsed_ocr_result
      snapshot = snapshot_without_proposals(result)
      proposals = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )
      mutated = snapshot.deep_dup
      item = mutated.dig(:candidates, :items, 0)
      item.merge!(price: 999, quantity: 9, quantity_unit_code: 'box', line_total: 8_991)
      explicit_mutated = snapshot.deep_dup
      explicit_mutated.dig(:candidates, :items, 0)[:original_line_total] = 999

      aggregate_failures do
        expect(described_class.from_snapshot(proposals, ocr_snapshot: mutated)).to be_nil
        expect(described_class.from_snapshot(proposals, ocr_snapshot: explicit_mutated)).to be_nil
      end
    end

    it 'structured referenceのsource candidate・exact source・evidence改変を再構築時に拒否する' do
      result = parsed_structured_reference_result
      snapshot = snapshot_without_proposals(result)
      proposals = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )
      candidate_id_mutated = snapshot.deep_dup
      candidate_id_mutated.dig(
        :candidates,
        :reference_pricing_candidates,
        0
      )[:candidate_id] = 'azure_items_0_reference_pricing_changed'
      exact_source_mutated = snapshot.deep_dup
      exact_source_mutated.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :reference_quantity
      )[:amount] = '101'
      evidence_mutated = snapshot.deep_dup
      evidence_mutated.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :tax_inclusion_evidence
      )[:provider_span_start] = 3
      printed_total_span_mutated = snapshot.deep_dup
      printed_total_span_mutated.dig(
        :candidates,
        :reference_pricing_candidates,
        0,
        :printed_line_total,
        :evidence
      )[:provider_span_start] = 4

      aggregate_failures do
        expect(described_class.from_snapshot(proposals, ocr_snapshot: candidate_id_mutated)).to be_nil
        expect(described_class.from_snapshot(proposals, ocr_snapshot: exact_source_mutated)).to be_nil
        expect(described_class.from_snapshot(proposals, ocr_snapshot: evidence_mutated)).to be_nil
        expect(described_class.from_snapshot(proposals, ocr_snapshot: printed_total_span_mutated)).to be_nil
      end
    end

    it 'native Item外の内税根拠をcurrent total・taxと再照合する' do
      result = parsed_structured_inner_tax_reference_result
      snapshot = snapshot_without_proposals(result)
      proposals = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )
      total_mismatch = snapshot.deep_dup
      total_mismatch.dig(:candidates)[:total_amount] = 1702
      tax_mismatch = snapshot.deep_dup
      tax_mismatch.dig(:candidates)[:tax_amount] = 153

      aggregate_failures do
        expect(described_class.from_snapshot(proposals, ocr_snapshot: total_mismatch)).to be_nil
        expect(described_class.from_snapshot(proposals, ocr_snapshot: tax_mismatch)).to be_nil
      end
    end

    it 'structured referenceのduplicate、count mismatch、truncationを部分採用しない' do
      result = parsed_structured_reference_result
      snapshot = snapshot_without_proposals(result)
      candidates = result.dig(:candidates, :item_calculation_mode_candidates)
      duplicated = snapshot.deep_dup
      duplicated.dig(:candidates, :reference_pricing_candidates) <<
        duplicated.dig(:candidates, :reference_pricing_candidates, 0).deep_dup
      duplicated.dig(:candidate_counts, :reference_pricing_candidates).merge!(
        actual_count: 2,
        snapshot_count: 2
      )
      missing_id = snapshot.deep_dup
      missing_id.dig(:candidates, :reference_pricing_candidates) << {}
      missing_id.dig(:candidate_counts, :reference_pricing_candidates).merge!(
        actual_count: 2,
        snapshot_count: 2
      )
      mismatched = snapshot.deep_dup
      mismatched.dig(:candidate_counts, :reference_pricing_candidates)[:snapshot_count] = 0
      truncated = snapshot.deep_dup
      truncated.dig(:truncated)[:reference_pricing_candidates] = true

      aggregate_failures do
        expect(described_class.build_all(candidates: candidates, ocr_snapshot: duplicated)).to be_nil
        expect(described_class.build_all(candidates: candidates, ocr_snapshot: missing_id)).to be_nil
        expect(described_class.build_all(candidates: candidates, ocr_snapshot: mismatched)).to be_nil
        expect(described_class.build_all(candidates: candidates, ocr_snapshot: truncated)).to be_nil
      end
    end

    it 'fails closed for malformed types and collection bounds without partial output' do
      result = parsed_ocr_result
      snapshot = snapshot_without_proposals(result)
      proposals = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )
      malformed = proposals.deep_dup
      malformed.first['options'] = 'not-an-array'

      aggregate_failures do
        expect(described_class.from_snapshot(malformed, ocr_snapshot: snapshot)).to be_nil
        expect(described_class.from_snapshot(
          Array.new(described_class::MAX_SETS + 1) { proposals.first },
          ocr_snapshot: snapshot
        )).to be_nil
      end
    end

    it 'fails closed for failed, truncated, count-mismatched, or duplicate-identity OCR context' do
      result = parsed_ocr_result
      snapshot = snapshot_without_proposals(result)
      proposals = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )
      failed = snapshot.deep_dup
      failed[:success] = false
      truncated = snapshot.deep_dup
      truncated[:truncated][:item_calculation_mode_candidates] = true
      mismatched = snapshot.deep_dup
      mismatched[:candidate_counts][:item_calculation_mode_candidates][:snapshot_count] -= 1
      duplicated = snapshot.deep_dup
      duplicated.dig(:candidates, :items, 1)[:ocr_item_identity] =
        duplicated.dig(:candidates, :items, 0, :ocr_item_identity)

      aggregate_failures do
        expect(described_class.from_snapshot(proposals, ocr_snapshot: failed)).to be_nil
        expect(described_class.from_snapshot(proposals, ocr_snapshot: truncated)).to be_nil
        expect(described_class.from_snapshot(proposals, ocr_snapshot: mismatched)).to be_nil
        expect(described_class.from_snapshot(proposals, ocr_snapshot: duplicated)).to be_nil
      end
    end

    it 'rejects invalid encoding and normalized key collisions without raising' do
      result = parsed_ocr_result
      snapshot = snapshot_without_proposals(result)
      proposals = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )
      invalid_encoding = proposals.deep_dup
      invalid_encoding.first['candidate_id'] = "\xFF".b
      duplicate_key = proposals.deep_dup
      duplicate_key.first[:candidate_id] = duplicate_key.first['candidate_id']

      expect do
        aggregate_failures do
          expect(described_class.from_snapshot(invalid_encoding, ocr_snapshot: snapshot)).to be_nil
          expect(described_class.from_snapshot(duplicate_key, ocr_snapshot: snapshot)).to be_nil
        end
      end.not_to raise_error
    end

    it 'rejects the first over-bound identity, path, numeric token, and serialized proposal' do
      result = parsed_ocr_result
      snapshot = snapshot_without_proposals(result)
      proposals = described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )

      oversized_identity = proposals.deep_dup
      oversized_identity.first['item_identity'] = "a" * (described_class::MAX_ID_BYTES + 1)
      oversized_path = proposals.deep_dup
      oversized_path.first['source_field_path'] = "a" * (described_class::MAX_PATH_BYTES + 1)
      oversized_number = proposals.deep_dup
      oversized_number.first.dig('options', 0, 'source')['price_amount'] =
        "1" * (described_class::MAX_EXACT_NUMBER_BYTES + 1)
      oversized_serialized = proposals.deep_dup
      oversized_serialized.first['conflicts'] = Array.new(100, 'package')

      aggregate_failures do
        expect(described_class.from_snapshot(oversized_identity, ocr_snapshot: snapshot)).to be_nil
        expect(described_class.from_snapshot(oversized_path, ocr_snapshot: snapshot)).to be_nil
        expect(described_class.from_snapshot(oversized_number, ocr_snapshot: snapshot)).to be_nil
        expect(described_class.from_snapshot(oversized_serialized, ocr_snapshot: snapshot)).to be_nil
      end
    end

    it 'keeps false distinct from nil while canonicalizing integrity payloads' do
      canonical = described_class.send(
        :deep_canonical_value,
        { 'enabled' => false, enabled: true, 'optional' => nil }
      )

      expect(canonical).to eq('enabled' => false, 'optional' => nil)
    end

    it 'accepts the serialized byte ceilings and rejects the first byte above each ceiling' do
      proposal_overhead = JSON.generate('payload' => '').bytesize
      at_proposal_limit = {
        'payload' => 'a' * (described_class::MAX_SERIALIZED_BYTES - proposal_overhead)
      }
      above_proposal_limit = at_proposal_limit.deep_dup
      above_proposal_limit['payload'] << 'a'
      total_overhead = JSON.generate([ '' ]).bytesize
      at_total_limit = [
        'a' * (described_class::MAX_TOTAL_SERIALIZED_BYTES - total_overhead)
      ]
      above_total_limit = at_total_limit.deep_dup
      above_total_limit.first << 'a'

      aggregate_failures do
        expect(described_class.send(:serialized_within_bound?, at_proposal_limit)).to be(true)
        expect(described_class.send(:serialized_within_bound?, above_proposal_limit)).to be(false)
        expect(described_class.send(:total_serialized_within_bound?, at_total_limit)).to be(true)
        expect(described_class.send(:total_serialized_within_bound?, above_total_limit)).to be(false)
      end
    end
  end
end
