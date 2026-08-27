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

  def snapshot_without_proposals(result)
    result = result.deep_dup
    result[:candidates] = result.fetch(:candidates).deep_dup

    builder = Receipts::Processing::Runs::SnapshotBuilder.new
    candidates = builder.send(:ocr_candidates_snapshot, result.fetch(:candidates).deep_symbolize_keys)
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

  describe '.build_all' do
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
