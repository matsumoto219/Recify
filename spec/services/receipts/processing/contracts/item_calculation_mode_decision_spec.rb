require 'rails_helper'

RSpec.describe Receipts::Processing::Contracts::ItemCalculationModeDecision do
  def parsed_ocr_result(raw = nil)
    raw ||= JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def ocr_snapshot_without_proposals(result)
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

  def proposal_context_for(result = parsed_ocr_result, index: 0)
    snapshot = ocr_snapshot_without_proposals(result)
    proposals = described_class::PROPOSAL_CONTRACT.build_all(
      candidates: result.dig(:candidates, :item_calculation_mode_candidates),
      ocr_snapshot: snapshot
    )

    {
      proposal: proposals.fetch(index),
      proposals: proposals,
      snapshot: snapshot
    }
  end

  def result_for(context, **overrides)
    described_class.call(
      item_identity: overrides.fetch(:item_identity, context.dig(:proposal, 'item_identity')),
      item_proposals: overrides.fetch(:item_proposals, context.fetch(:proposals)),
      ocr_snapshot: overrides.fetch(:ocr_snapshot, context.fetch(:snapshot)),
      count_tax_semantics: overrides.fetch(:count_tax_semantics, 'reproducible_as_recorded'),
      item_price_limit: overrides.fetch(:item_price_limit, 999_999_999),
      item_line_total_limit: overrides.fetch(:item_line_total_limit, 999_999_999)
    )
  end

  def raw_without(*field_names)
    raw = JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)
    item = raw.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray', 0)
    field_names.each { |field_name| item.fetch('valueObject').delete(field_name) }
    raw
  end

  def raw_with_first_total(amount)
    raw = JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)
    analyze_result = raw.fetch('analyzeResult')
    item = analyze_result.dig('documents', 0, 'fields', 'Items', 'valueArray', 0)
    total = item.dig('valueObject', 'TotalPrice')
    content = "¥#{amount}"
    raise 'test fixture replacement must preserve span length' unless content.length == total.fetch('content').length

    parent_offset = item.fetch('spans').sole.fetch('offset')
    total_offset = total.fetch('spans').sole.fetch('offset')
    total_length = total.fetch('spans').sole.fetch('length')
    analyze_result.fetch('content')[total_offset, total_length] = content
    item.fetch('content')[total_offset - parent_offset, total_length] = content
    total['content'] = content
    total.fetch('valueCurrency')['amount'] = amount
    raw
  end

  def parsed_structured_zero_result(formula:)
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_item_calculation_reference_gross_anonymized.json').read
    )
    analyze_result = raw.fetch('analyzeResult')
    document = analyze_result.fetch('documents').sole
    item = document.dig('fields', 'Items', 'valueArray').sole
    fields = item.fetch('valueObject')
    lines = analyze_result.fetch('pages').sole.fetch('lines')
    if formula
      content = "検証品\n¥0\n1 個\n¥0"
      lines[1].merge!('content' => '¥0', 'spans' => [ { 'offset' => 4, 'length' => 2 } ])
      lines[2].merge!('content' => '1 個', 'spans' => [ { 'offset' => 7, 'length' => 3 } ])
      lines[3].merge!('content' => '¥0', 'spans' => [ { 'offset' => 11, 'length' => 2 } ])
      fields.fetch('Price').merge!(
        'content' => '¥0',
        'spans' => [ { 'offset' => 4, 'length' => 2 } ],
        'valueCurrency' => { 'currencySymbol' => '¥', 'amount' => 0, 'currencyCode' => 'JPY' }
      )
      fields.fetch('Quantity').merge!(
        'content' => '1',
        'spans' => [ { 'offset' => 7, 'length' => 1 } ],
        'valueNumber' => 1
      )
      fields.fetch('QuantityUnit').merge!(
        'content' => '個',
        'spans' => [ { 'offset' => 9, 'length' => 1 } ],
        'valueString' => '個'
      )
    else
      content = "検証品\n¥0"
      lines.replace([
        lines[0],
        lines[3].merge('content' => '¥0', 'spans' => [ { 'offset' => 4, 'length' => 2 } ])
      ])
      %w[Price Quantity QuantityUnit].each { |field| fields.delete(field) }
    end
    total_offset = formula ? 11 : 4
    fields.fetch('TotalPrice').merge!(
      'content' => '¥0',
      'spans' => [ { 'offset' => total_offset, 'length' => 2 } ],
      'valueCurrency' => { 'currencySymbol' => '¥', 'amount' => 0, 'currencyCode' => 'JPY' }
    )
    analyze_result['content'] = content
    analyze_result.fetch('pages').sole.fetch('spans').sole['length'] = content.length
    document.fetch('spans').sole['length'] = content.length
    item.merge!('content' => content, 'spans' => [ { 'offset' => 0, 'length' => content.length } ])

    parsed_ocr_result(raw)
  end

  def parsed_structured_reference_result(
    with_total: true,
    total_amount: 1703,
    tax_marker: '税込',
    reference_price_amount: 498
  )
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_item_calculation_reference_gross_anonymized.json').read
    )
    analyze_result = raw.fetch('analyzeResult')
    document = analyze_result.fetch('documents').sole
    item = document.dig('fields', 'Items', 'valueArray').sole
    price = item.dig('valueObject', 'Price')
    price_content = "#{tax_marker} ¥#{reference_price_amount}/100g"
    raise 'test fixture replacement must preserve span length' unless price_content.length == 12

    analyze_result.fetch('content')[4, 12] = price_content
    item.fetch('content')[4, 12] = price_content
    price['content'] = price_content
    price.fetch('valueCurrency')['amount'] = reference_price_amount
    if with_total
      total = item.dig('valueObject', 'TotalPrice')
      content = "¥#{total_amount.to_s.reverse.scan(/.{1,3}/).join(',').reverse}"
      raise 'test fixture replacement must preserve span length' unless content.length == 6

      analyze_result.fetch('content')[22, 6] = content
      item.fetch('content')[22, 6] = content
      total['content'] = content
      total.fetch('valueCurrency')['amount'] = total_amount
    else
      content = "検証品\n#{price_content}\n342g"
      analyze_result['content'] = content
      analyze_result.fetch('pages').sole.fetch('lines').pop
      analyze_result.fetch('pages').sole.fetch('spans').sole['length'] = content.length
      document.fetch('spans').sole['length'] = content.length
      item['content'] = content
      item.fetch('spans').sole['length'] = content.length
      item.fetch('valueObject').delete('TotalPrice')
    end

    parsed_ocr_result(raw)
  end

  def parsed_structured_implicit_reference_result
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_item_calculation_reference_gross_anonymized.json').read
    )
    analyze_result = raw.fetch('analyzeResult')
    document = analyze_result.fetch('documents').sole
    item = document.dig('fields', 'Items', 'valueArray').sole
    fields = item.fetch('valueObject')
    content = "検証品\n税込 ¥5/g\n0.342kg\n¥1,710"

    analyze_result['content'] = content
    analyze_result.fetch('pages').sole.fetch('spans').sole['length'] = 26
    lines = analyze_result.fetch('pages').sole.fetch('lines')
    lines[1].merge!('content' => '税込 ¥5/g', 'spans' => [ { 'offset' => 4, 'length' => 7 } ])
    lines[2].merge!('content' => '0.342kg', 'spans' => [ { 'offset' => 12, 'length' => 7 } ])
    lines[3].merge!('content' => '¥1,710', 'spans' => [ { 'offset' => 20, 'length' => 6 } ])
    document.fetch('spans').sole['length'] = 26
    item.merge!('content' => content, 'spans' => [ { 'offset' => 0, 'length' => 26 } ])
    fields.fetch('Price').merge!(
      'content' => '税込 ¥5/g',
      'spans' => [ { 'offset' => 4, 'length' => 7 } ],
      'valueCurrency' => { 'currencySymbol' => '¥', 'amount' => 5, 'currencyCode' => 'JPY' }
    )
    fields.fetch('Quantity').merge!(
      'content' => '0.342kg',
      'spans' => [ { 'offset' => 12, 'length' => 7 } ],
      'valueNumber' => 0.342
    )
    fields.fetch('QuantityUnit').merge!(
      'content' => 'kg',
      'spans' => [ { 'offset' => 17, 'length' => 2 } ],
      'valueString' => 'kg'
    )
    fields.fetch('TotalPrice').merge!(
      'content' => '¥1,710',
      'spans' => [ { 'offset' => 20, 'length' => 6 } ],
      'valueCurrency' => { 'currencySymbol' => '¥', 'amount' => 1710, 'currencyCode' => 'JPY' }
    )

    parsed_ocr_result(raw)
  end

  def counted_application_queries
    queries = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:name].in?(%w[SCHEMA CACHE])
      next if payload[:sql].match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)

      queries << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { yield }
    queries
  end

  describe '.call' do
    it '単価×明示数量が同一Itemの印字合計と一致する場合はcount formulaをconfirmedにする' do
      decision = result_for(proposal_context_for)

      aggregate_failures do
        expect(decision).to be_confirmed
        expect(decision.state).to eq('confirmed')
        expect(decision.reason).to eq('formula_matches_printed_total')
        expect(decision.selected_proposal_id).to eq('azure_items_0_count_unit_price')
        expect(decision.selected_pricing_source_kind).to eq('count_unit_price')
        expect(decision.projected_line_total).to eq(220)
        expect(decision.option_proposal_ids).to eq(%w[
          azure_items_0_count_unit_price
          azure_items_0_explicit_line_total
        ])
      end
    end

    it 'formulaと印字合計が一致しない場合は印字額を維持してreviewableにする' do
      context = proposal_context_for(parsed_ocr_result(raw_with_first_total(221)))
      decision = result_for(context)

      aggregate_failures do
        expect(decision).to be_reviewable
        expect(decision.reason).to eq('formula_total_mismatch')
        expect(decision.selected_proposal_id).to eq('azure_items_0_explicit_line_total')
        expect(decision.selected_pricing_source_kind).to eq('explicit_line_total')
        expect(decision.projected_line_total).to eq(221)
      end
    end

    it 'strong printed totalだけならexplicitをconfirmedにする' do
      context = proposal_context_for(parsed_ocr_result(raw_without('Price', 'Quantity', 'QuantityUnit')))
      decision = result_for(context)

      aggregate_failures do
        expect(decision).to be_confirmed
        expect(decision.reason).to eq('explicit_total_only')
        expect(decision.selected_pricing_source_kind).to eq('explicit_line_total')
        expect(decision.projected_line_total).to eq(220)
      end
    end

    it '明示0円を欠損と区別してexplicitとしてconfirmedにする' do
      context = proposal_context_for(parsed_structured_zero_result(formula: false))

      decision = result_for(context)

      aggregate_failures do
        expect(decision).to be_confirmed
        expect(decision.reason).to eq('explicit_total_only')
        expect(decision.selected_pricing_source_kind).to eq('explicit_line_total')
        expect(decision.projected_line_total).to eq(0)
      end
    end

    it '0円formulaと印字0円が一致する場合もcount formulaをconfirmedにする' do
      context = proposal_context_for(parsed_structured_zero_result(formula: true))

      decision = result_for(context)

      aggregate_failures do
        expect(decision).to be_confirmed
        expect(decision.reason).to eq('formula_matches_printed_total')
        expect(decision.selected_pricing_source_kind).to eq('count_unit_price')
        expect(decision.projected_line_total).to eq(0)
      end
    end

    it 'formulaも印字合計も欠損する場合はauthorityを作らずunresolvedにする' do
      result = parsed_ocr_result(raw_without('Price', 'Quantity', 'QuantityUnit', 'TotalPrice'))
      snapshot = ocr_snapshot_without_proposals(result)

      decision = described_class.call(
        item_identity: 'missing',
        item_proposals: [],
        ocr_snapshot: snapshot,
        count_tax_semantics: 'reproducible_as_recorded',
        item_price_limit: 999_999_999,
        item_line_total_limit: 999_999_999
      )

      aggregate_failures do
        expect(decision).to be_unresolved
        expect(decision.reason).to eq('proposal_invalid')
        expect(decision.selected_proposal_id).to be_nil
        expect(decision.projected_line_total).to be_nil
      end
    end

    it '印字合計がないcount formulaは税semanticsを推測せずunresolvedにする' do
      context = proposal_context_for(parsed_ocr_result(raw_without('TotalPrice')))
      decision = result_for(context, count_tax_semantics: 'unknown')

      aggregate_failures do
        expect(decision).to be_unresolved
        expect(decision.reason).to eq('count_tax_semantics_unknown')
        expect(decision.selected_proposal_id).to be_nil
        expect(decision.projected_line_total).to be_nil
      end
    end

    it '印字合計がないcount formulaもas-recorded税semanticsを再現できる場合だけconfirmedにする' do
      context = proposal_context_for(parsed_ocr_result(raw_without('TotalPrice')))
      decision = result_for(context)

      aggregate_failures do
        expect(decision).to be_confirmed
        expect(decision.reason).to eq('count_formula_only')
        expect(decision.selected_pricing_source_kind).to eq('count_unit_price')
        expect(decision.projected_line_total).to eq(220)
      end
    end

    it '印字合計一致でもcount税semanticsが不明なら現在金額を維持してreviewableにする' do
      context = proposal_context_for
      decision = result_for(context, count_tax_semantics: 'unknown')

      aggregate_failures do
        expect(decision).to be_reviewable
        expect(decision.reason).to eq('count_tax_semantics_unknown')
        expect(decision.selected_pricing_source_kind).to eq('count_unit_price')
        expect(decision.projected_line_total).to eq(220)
      end
    end

    it 'grossの基準価格formulaが印字合計と一致する場合はreferenceをconfirmedにする' do
      context = proposal_context_for(parsed_structured_reference_result)
      decision = result_for(context, count_tax_semantics: 'unknown')

      aggregate_failures do
        expect(decision).to be_confirmed
        expect(decision.reason).to eq('formula_matches_printed_total')
        expect(decision.selected_proposal_id).to eq('azure_items_0_reference_quantity_price')
        expect(decision.selected_pricing_source_kind).to eq('reference_quantity_price')
        expect(decision.projected_line_total).to eq(1703)
      end
    end

    it 'grossの基準価格formulaと印字合計が不一致ならexplicitをreviewableにする' do
      context = proposal_context_for(
        parsed_structured_reference_result(total_amount: 1699, reference_price_amount: 497)
      )
      decision = result_for(context, count_tax_semantics: 'unknown')

      aggregate_failures do
        expect(
          context.dig(
            :snapshot,
            :candidates,
            :reference_pricing_candidates,
            0,
            :corroboration,
            :rounding_matches
          )
        ).to eq([ 'floor' ])
        expect(decision).to be_reviewable
        expect(decision.reason).to eq('formula_total_mismatch')
        expect(decision.selected_pricing_source_kind).to eq('explicit_line_total')
        expect(decision.projected_line_total).to eq(1699)
      end
    end

    it '印字合計がないgrossの基準価格formulaをreferenceとしてconfirmedにする' do
      context = proposal_context_for(parsed_structured_reference_result(with_total: false))
      decision = result_for(context, count_tax_semantics: 'unknown')

      aggregate_failures do
        expect(decision).to be_confirmed
        expect(decision.reason).to eq('reference_formula_only')
        expect(decision.selected_pricing_source_kind).to eq('reference_quantity_price')
        expect(decision.projected_line_total).to eq(1703)
      end
    end

    it 'implicit per-unitとkgかgへのexact変換をreference formulaとしてconfirmedにする' do
      context = proposal_context_for(parsed_structured_implicit_reference_result)

      decision = result_for(context, count_tax_semantics: 'unknown')

      aggregate_failures do
        expect(context.dig(:proposal, 'options', 0, 'source')).to include(
          'reference_quantity' => '1',
          'reference_quantity_origin' => 'implicit_per_unit',
          'reference_quantity_unit_code' => 'gram',
          'purchased_quantity' => '0.342',
          'purchased_quantity_unit_code' => 'kilogram'
        )
        expect(decision).to be_confirmed
        expect(decision.selected_pricing_source_kind).to eq('reference_quantity_price')
        expect(decision.projected_line_total).to eq(1710)
      end
    end

    it 'netの基準価格formulaは初版でauthorityにせずstrong totalだけをreviewableに維持する' do
      with_total = proposal_context_for(parsed_structured_reference_result(tax_marker: '税抜'))
      without_total = proposal_context_for(
        parsed_structured_reference_result(with_total: false, tax_marker: '税抜')
      )

      aggregate_failures do
        expect(result_for(with_total)).to be_reviewable
        expect(result_for(with_total).selected_pricing_source_kind).to eq('explicit_line_total')
        expect(result_for(with_total).reason).to eq('reference_tax_semantics_unsupported')
        expect(result_for(without_total)).to be_unresolved
        expect(result_for(without_total).reason).to eq('reference_tax_semantics_unsupported')
      end
    end

    it 'source上限ちょうどを許可し、上限を1円でも超えるprojectionを拒否する' do
      context = proposal_context_for

      aggregate_failures do
        expect(result_for(context, item_price_limit: 220, item_line_total_limit: 220)).to be_confirmed
        expect(result_for(context, item_price_limit: 219)).to be_unresolved
        expect(result_for(context, item_line_total_limit: 219)).to be_unresolved
      end
    end

    it 'reference projectionの上限ちょうどを許可し、最初の超過を拒否する' do
      context = proposal_context_for(parsed_structured_reference_result)

      aggregate_failures do
        expect(result_for(context, item_line_total_limit: 1703)).to be_confirmed
        expect(result_for(context, item_line_total_limit: 1702)).to be_unresolved
      end
    end

    it 'unknown count tax semanticsとitem identity不一致をfail-closedにする' do
      context = proposal_context_for

      aggregate_failures do
        expect(result_for(context, count_tax_semantics: 'invented')).to be_unresolved
        expect(result_for(context, item_identity: 'unknown')).to be_unresolved
      end
    end

    it 'unknown version、source改変、duplicate ID、unknown modeをcanonical contractでfail-closedにする' do
      context = proposal_context_for
      proposal = context.fetch(:proposal)
      malformed = [
        proposal.deep_dup.tap { |value| value['schema_version'] = 'item_calculation_mode_proposal_set_v2' },
        proposal.deep_dup.tap do |value|
          value.dig('options', 0, 'source')['price_amount'] = '221'
          value['integrity_checksum'] = 'a' * 64
        end,
        proposal.deep_dup.tap { |value| value['options'][1]['proposal_id'] = value['options'][0]['proposal_id'] },
        proposal.deep_dup.tap { |value| value['options'][0]['pricing_source_kind'] = 'unknown' }
      ]

      malformed.each do |value|
        decision = result_for(context, item_proposals: [ value ])

        aggregate_failures do
          expect(decision).to be_unresolved
          expect(decision.reason).to eq('proposal_invalid')
          expect(decision.selected_proposal_id).to be_nil
        end
      end
    end

    it '入力を変更せず、返却値とnested ID一覧をimmutableにする' do
      context = proposal_context_for
      before = context.deep_dup
      decision = result_for(context)

      aggregate_failures do
        expect(context).to eq(before)
        expect(decision).to be_frozen
        expect(decision.option_proposal_ids).to be_frozen
        expect(decision.option_proposal_ids).to all(be_frozen)
      end
    end

    it 'DB・SystemSetting・provider・AI・current timeに依存しない' do
      context = proposal_context_for
      expect(SystemSettings).not_to receive(:fetch)
      expect(SystemSettings).not_to receive(:limit_for)
      expect(SystemSettings).not_to receive(:limits_for)
      expect(ReceiptOcrService).not_to receive(:call)
      expect(ReceiptAiEnrichmentService).not_to receive(:call)
      expect(Time).not_to receive(:current)

      decision = nil
      queries = counted_application_queries { decision = result_for(context) }

      aggregate_failures do
        expect(decision).to be_confirmed
        expect(queries).to be_empty
      end
    end
  end

  describe '.call_all' do
    it 'canonical proposal集合を1回だけ検証し、全itemの判定を返す' do
      context = proposal_context_for
      allow(described_class::PROPOSAL_CONTRACT).to receive(:from_snapshot).and_call_original

      decisions = described_class.call_all(
        item_proposals: context.fetch(:proposals),
        ocr_snapshot: context.fetch(:snapshot),
        count_tax_semantics: 'reproducible_as_recorded',
        item_price_limit: 999_999_999,
        item_line_total_limit: 999_999_999
      )

      aggregate_failures do
        expect(decisions.size).to eq(4)
        expect(decisions).to all(be_confirmed)
        expect(decisions.map(&:item_identity)).to eq(
          context.fetch(:proposals).map { |proposal| proposal.fetch('item_identity') }.sort
        )
        expect(described_class::PROPOSAL_CONTRACT).to have_received(:from_snapshot).once
      end
    end

    it 'proposal集合が改変されている場合は一部判定を返さない' do
      context = proposal_context_for
      malformed = context.fetch(:proposals).deep_dup
      malformed.first['integrity_checksum'] = '0' * 64

      expect(
        described_class.call_all(
          item_proposals: malformed,
          ocr_snapshot: context.fetch(:snapshot),
          count_tax_semantics: 'reproducible_as_recorded',
          item_price_limit: 999_999_999,
          item_line_total_limit: 999_999_999
        )
      ).to be_nil
    end
  end
end
