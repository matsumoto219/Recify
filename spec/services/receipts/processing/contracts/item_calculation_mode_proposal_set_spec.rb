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

  def parsed_structured_reference_result(with_total: true, string_index_type: 'utf16CodeUnit')
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_item_calculation_reference_gross_anonymized.json').read
    )
    raw.dig('analyzeResult')['stringIndexType'] = string_index_type
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

    it 'structured reference evidenceはUTF-16 indexに限定しtextElementsではfail-closedにする' do
      result = parsed_structured_reference_result(string_index_type: 'textElements')
      snapshot = snapshot_without_proposals(result)

      expect(described_class.build_all(
        candidates: result.dig(:candidates, :item_calculation_mode_candidates),
        ocr_snapshot: snapshot
      )).to be_nil
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
