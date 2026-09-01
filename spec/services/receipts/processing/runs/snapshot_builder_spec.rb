require 'rails_helper'

RSpec.describe Receipts::Processing::Runs::SnapshotBuilder do
  def destination_ocr_result
    raw_json = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
    )

    Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
  end

  def structured_count_ocr_result
    raw_json = JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)

    Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
  end

  def structured_count_without_totals_ocr_result
    raw_json = JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)
    raw_json.dig('analyzeResult', 'documents', 0, 'fields', 'Items', 'valueArray').each do |item|
      item.fetch('valueObject').delete('TotalPrice')
    end

    Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
  end

  def structured_reference_ocr_result
    raw_json = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_item_calculation_reference_gross_anonymized.json').read
    )

    Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
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
            reference_line_provider_span_start: 26,
            reference_line_provider_span_end: 40,
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
            destination_kind: 'azure_layout_item',
            provider_model_id: 'prebuilt-receipt',
            provider_api_version: '2024-11-30',
            string_index_type: 'textElements',
            source_field_path: 'pages[0].lines[1]',
            provider_span_start: 16,
            provider_span_end: 66,
            destination_evidence: evidence.call(1, 16, 22),
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
                evidence: {
                  line_total: evidence.call(4, 49, 55)
                }
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

  def shared_basis_diagnostic_ocr_result
    result = item_layout_ocr_result.deep_dup
    item_identity = 'azure_structured_item_i0_s16_e55'
    candidate = result.dig(:candidates, :reference_pricing_candidates).sole
    mode_candidate = result.dig(:candidates, :item_calculation_mode_candidates).sole
    header_evidence = candidate.dig(:reference_quantity, :evidence).merge(
      source_field_path: 'pages[0].lines[0]',
      line_index: 0,
      provider_span_start: 0,
      provider_span_end: 4
    )

    result.dig(:candidates, :items, 0)[:ocr_item_identity] = item_identity
    candidate.merge!(
      item_identity: item_identity,
      destination_kind: 'azure_structured_item',
      structured_item_index: 0,
      validation_contract_version: 'azure_item_layout_shared_basis_v1',
      block_provider_span_start: 16,
      block_provider_span_end: 55,
      owned_line_indexes: [ 0, 1, 2, 3, 4 ],
      validation_state: 'ambiguous',
      rejection_reasons: [ 'ambiguous_tax_inclusion' ],
      reference_price_tax_inclusion: 'unknown',
      tax_inclusion_evidence: nil
    )
    candidate.dig(:reference_quantity)[:evidence] = header_evidence
    mode_candidate.replace(
      candidate_id: 'azure_items_0_item_calculation_mode',
      item_identity: item_identity,
      item_index: 0,
      source_provider: 'azure_structured',
      provider_model_id: 'prebuilt-receipt',
      provider_api_version: '2024-11-30',
      string_index_type: 'textElements',
      source_field_path: 'documents[0].fields.Items[0]',
      provider_span_start: 16,
      provider_span_end: 55,
      destination_evidence: {
        source_field_path: 'documents[0].fields.Items[0].Description',
        provider_span_start: 16,
        provider_span_end: 22
      },
      printed_line_total: {
        amount: '1703',
        evidence: {
          source_field_path: 'documents[0].fields.Items[0].TotalPrice',
          provider_span_start: 49,
          provider_span_end: 55
        }
      },
      conflicts: [],
      options: [
        {
          proposal_id: 'azure_items_0_explicit_line_total',
          pricing_source_kind: 'explicit_line_total',
          source: { line_total_amount: '1703' },
          evidence: {
            line_total: {
              source_field_path: 'documents[0].fields.Items[0].TotalPrice',
              provider_span_start: 49,
              provider_span_end: 55
            }
          }
        }
      ]
    )
    result
  end

  def move_shared_basis_row_indexes!(result, name_line_index:)
    candidate = result.dig(:candidates, :reference_pricing_candidates).sole
    reference_line_index = name_line_index + 1
    quantity_line_index = name_line_index + 2
    total_line_index = name_line_index + 3
    candidate.merge!(
      candidate_id: "azure_item_layout_p0_name_l#{name_line_index}_ref_l#{reference_line_index}_" \
        "qty_l#{quantity_line_index}_total_l#{total_line_index}_reference_pricing",
      name_line_index: name_line_index,
      reference_line_index: reference_line_index,
      purchased_quantity_line_indexes: [ quantity_line_index ],
      printed_total_line_index: total_line_index,
      owned_line_indexes: [ 0, *(name_line_index..total_line_index) ]
    )
    {
      reference_price: reference_line_index,
      purchased_quantity: quantity_line_index,
      printed_line_total: total_line_index
    }.each do |component, line_index|
      candidate.dig(component, :evidence).merge!(
        source_field_path: "pages[0].lines[#{line_index}]",
        line_index: line_index
      )
    end
  end

  def single_item_gross_summary_ocr_result
    result = item_layout_ocr_result.deep_dup
    result[:lines] << '10%対象 1,549円 内税154円'
    result[:case_preserved_lines] << '10%対象 1,549円 内税154円'
    result.dig(:candidates).merge!(total_amount: 1703, tax_amount: 154)

    item_identity = 'azure_structured_item_i0_s16_e38'
    result.dig(:candidates, :items, 0)[:ocr_item_identity] = item_identity
    reference = result.dig(:candidates, :reference_pricing_candidates).sole
    reference.merge!(
      item_identity: item_identity,
      destination_kind: 'azure_structured_item',
      structured_item_index: 0,
      reference_price_tax_inclusion: 'gross',
      validation_state: 'valid',
      rejection_reasons: [],
      tax_inclusion_evidence: {
        kind: 'single_item_receipt_gross_summary',
        string_index_type: 'textElements',
        policy_contract_version: 'reference_pricing_single_item_gross_summary_policy_v1',
        summary_total: {
          source_provider: 'azure_item_layout',
          source_field_path: 'pages[0].lines[5]',
          page_index: 0,
          line_index: 5,
          string_index_type: 'textElements',
          provider_span_start: 70,
          provider_span_end: 80,
          amount: 1703
        },
        gross_tax_target: {
          source_provider: 'azure_item_layout',
          source_field_path: 'pages[0].lines[6]',
          page_index: 0,
          line_index: 6,
          string_index_type: 'textElements',
          provider_span_start: 82,
          provider_span_end: 105,
          rate: '0.1',
          net_amount: 1549,
          tax_amount: 154,
          gross_amount: 1703
        }
      }
    )
    result.dig(:candidates, :item_calculation_mode_candidates).sole.merge!(
      item_identity: item_identity,
      destination_kind: 'azure_structured_item',
      owned_line_indexes: [ 1, 2, 3, 4 ]
    )
    result
  end

  def single_structured_item_inner_tax_ocr_result
    result = structured_reference_ocr_result.deep_dup
    result[:lines].concat([ '内消費税等', '154円', '合計', '1,703円' ])
    result[:case_preserved_lines].concat([ '内消費税等', '154円', '合計', '1,703円' ])
    result.dig(:candidates).merge!(total_amount: 1703, tax_amount: 154)

    reference = result.dig(:candidates, :reference_pricing_candidates).sole
    reference.merge!(
      reference_price_tax_inclusion: 'gross',
      validation_state: 'valid',
      rejection_reasons: [],
      tax_inclusion_evidence: {
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
        tax_description: {
          source_provider: 'azure_structured',
          source_field_path: 'documents[0].fields.TaxDetails[0].Description',
          tax_detail_index: 0,
          page_index: 0,
          line_index: 4,
          string_index_type: 'utf16CodeUnit',
          provider_span_start: 30,
          provider_span_end: 35
        },
        tax_amount: {
          source_provider: 'azure_structured',
          source_field_path: 'documents[0].fields.TaxDetails[0].Amount',
          tax_detail_index: 0,
          page_index: 0,
          line_index: 5,
          string_index_type: 'utf16CodeUnit',
          provider_span_start: 36,
          provider_span_end: 39,
          amount: 154
        },
        document_tax_total: {
          source_provider: 'azure_structured',
          source_field_path: 'documents[0].fields.TotalTax',
          page_index: 0,
          line_index: 5,
          string_index_type: 'utf16CodeUnit',
          provider_span_start: 36,
          provider_span_end: 39,
          amount: 154
        },
        summary_total: {
          source_provider: 'azure_document_total',
          source_field_path: 'pages[0].lines[7]',
          page_index: 0,
          line_index: 7,
          string_index_type: 'utf16CodeUnit',
          provider_span_start: 44,
          provider_span_end: 49,
          amount: 1703
        }
      }
    )
    result
  end

  def discount_heavy_ocr_result
    raw_json = JSON.parse(Rails.root.join('spec/fixtures/ocr/discount_heavy_receipt.json').read)

    Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
  end

  it 'invalid categoryを保存せず未分類の確認状態だけをsnapshotへ残す' do
    snapshot = described_class.ai_normalized_result_snapshot(
      success: true,
      needs_review: false,
      review_reasons: [],
      receipt_items_attributes: [
        { index: 0, category: 'unknown_category', needs_review: false }
      ]
    )
    item = snapshot.fetch('receipt_items_attributes').first

    aggregate_failures do
      expect(item).not_to have_key('category')
      expect(item['needs_review']).to be(true)
      expect(item['review_reasons']).to include('item_category_uncertain')
      expect(snapshot['needs_review']).to be(true)
      expect(snapshot['review_reasons']).to include('item_category_uncertain')
      expect(snapshot.to_json).not_to include('unknown_category')
    end
  end

  it '明示されたotherはsnapshotでも独立した有効categoryとして保持する' do
    snapshot = described_class.ai_normalized_result_snapshot(
      success: true,
      needs_review: false,
      review_reasons: [],
      receipt_items_attributes: [
        { index: 0, category: 'other', needs_review: false }
      ]
    )

    expect(snapshot.dig('receipt_items_attributes', 0, 'category')).to eq('other')
  end

  it '前後空白を含むcanonical categoryを正規化してsnapshotへ保持する' do
    snapshot = described_class.ai_normalized_result_snapshot(
      success: true,
      needs_review: false,
      review_reasons: [],
      receipt_items_attributes: [
        { index: 0, category: ' other ', needs_review: false }
      ]
    )
    item = snapshot.fetch('receipt_items_attributes').first

    aggregate_failures do
      expect(item['category']).to eq('other')
      expect(item['needs_review']).to be(false)
      expect(item.fetch('review_reasons', [])).not_to include('item_category_uncertain')
      expect(snapshot['needs_review']).to be(false)
    end
  end

  it 'build params snapshotにはraw source refsやdiagnosticsを含めず安全なownership contractだけを残す' do
    snapshot = described_class.build_params_snapshot(
      receipt_attributes: { total_amount: 100 },
      receipt_items_attributes: [],
      receipt_adjustments_attributes: [],
      receipt_payments_attributes: [],
      receipt_tax_details_attributes: [],
      review_reasons: [],
      ownership_contract: {
        schema_version: 1,
        duplicate_source_owner_count: 1,
        payment_source_purchase_adjustment_count: 2,
        tax_detail_source_effect_count: 3,
        unknown_purchase_tax_allocation_count: 4,
        adjustment_review_required_count: 5,
        source_refs: [ { source_text: 'RAW OCR SOURCE TEXT' } ],
        diagnostics: [ { normalized_text: 'RAW OCR NORMALIZED TEXT' } ]
      }
    )

    aggregate_failures do
      expect(snapshot['ownership_contract']).to eq(
        'schema_version' => 1,
        'duplicate_source_owner_count' => 1,
        'payment_source_purchase_adjustment_count' => 2,
        'tax_detail_source_effect_count' => 3,
        'unknown_purchase_tax_allocation_count' => 4,
        'adjustment_review_required_count' => 5
      )
      expect(snapshot.to_json).not_to include('RAW OCR SOURCE TEXT', 'RAW OCR NORMALIZED TEXT')
      expect(snapshot.to_json).not_to include('source_refs', 'diagnostics')
    end
  end

  it 'OCR itemの数量単位判定を専用allowlistと64-byte上限で保存する' do
    snapshot = described_class.ocr_result_snapshot(
      success: true,
      candidates: {
        items: [
          {
            raw_text: '量り売り商品',
            quantity: '2',
            quantity_unit_code: nil,
            quantity_unit_status: 'unknown',
            quantity_unit_raw: '杯' * 100,
            quantity_unit_source_text: '保存しない数量単位周辺のOCR全文'
          }
        ]
      }
    )
    item = snapshot.dig('candidates', 'items', 0)

    aggregate_failures do
      expect(item['quantity_unit_status']).to eq('unknown')
      expect(item['quantity_unit_raw'].bytesize).to be <= 64
      expect(item).not_to have_key('quantity_unit_source_text')
      expect(snapshot.to_json).not_to include('保存しない数量単位周辺のOCR全文')
    end
  end

  it '不正なOCR item数量単位判定はsnapshotへ保存しない' do
    snapshot = described_class.ocr_result_snapshot(
      success: true,
      candidates: {
        items: [
          {
            raw_text: '量り売り商品',
            quantity_unit_status: 'invented',
            quantity_unit_raw: '杯'
          }
        ]
      }
    )

    expect(snapshot.dig('candidates', 'items', 0)).not_to have_key('quantity_unit_status')
  end

  it 'known数量単位のraw表記はsnapshotへ重複保存しない' do
    snapshot = described_class.ocr_result_snapshot(
      success: true,
      candidates: {
        items: [
          {
            raw_text: '量り売り商品',
            quantity_unit_code: 'gram',
            quantity_unit_status: 'known',
            quantity_unit_raw: 'g'
          }
        ]
      }
    )

    item = snapshot.dig('candidates', 'items', 0)

    aggregate_failures do
      expect(item).to include(
        'quantity_unit_code' => 'gram',
        'quantity_unit_status' => 'known'
      )
      expect(item).not_to have_key('quantity_unit_raw')
    end
  end

  it 'build params snapshotはreference pricing候補をstate/reason件数だけへ集約する' do
    snapshot = described_class.build_params_snapshot(
      receipt_attributes: { total_amount: 1_703 },
      receipt_items_attributes: [],
      receipt_adjustments_attributes: [],
      receipt_payments_attributes: [],
      receipt_tax_details_attributes: [],
      reference_pricing_candidates: [
        {
          candidate_id: 'azure_items_0_reference_pricing',
          validation_state: 'valid',
          rejection_reasons: [],
          reference_price: {
            amount: '498',
            evidence: {
              source_field_path: 'documents[0].fields.Items[0].Price',
              source_text: '保存しない価格OCR全文'
            }
          }
        },
        {
          candidate_id: 'azure_items_1_reference_pricing',
          validation_state: 'unsupported',
          rejection_reasons: %w[unsupported_reference_unit incompatible_unit_dimension],
          reference_quantity: {
            amount: '100',
            unit_status: 'unknown',
            unit_raw: '保存しない候補単位raw'
          }
        }
      ]
    )

    aggregate_failures do
      expect(snapshot['reference_pricing_candidates']).to eq(
        'candidate_count' => 2,
        'validation_state_counts' => {
          'valid' => 1,
          'unsupported' => 1
        },
        'reason_counts' => {
          'incompatible_unit_dimension' => 1,
          'unsupported_reference_unit' => 1
        }
      )
      expect(snapshot.to_json).not_to include(
        'azure_items_0_reference_pricing',
        'documents[0].fields.Items[0].Price',
        '保存しない価格OCR全文',
        '498',
        '100',
        '保存しない候補単位raw'
      )
    end
  end

  it 'build params snapshotのreference pricing集計は未知state/reasonと過剰件数をfail closedに扱う' do
    candidates = Array.new(101) do
      {
        validation_state: 'invented_state',
        rejection_reasons: [ 'invented_reason', 'unsupported_reference_unit' ]
      }
    end

    snapshot = described_class.build_params_snapshot(
      receipt_attributes: {},
      receipt_items_attributes: [],
      receipt_adjustments_attributes: [],
      receipt_payments_attributes: [],
      receipt_tax_details_attributes: [],
      reference_pricing_candidates: candidates
    )

    expect(snapshot['reference_pricing_candidates']).to eq(
      'candidate_count' => 100,
      'validation_state_counts' => {},
      'reason_counts' => { 'unsupported_reference_unit' => 100 }
    )
  end

  it 'reference pricing candidateを専用allowlistでbounded OCR snapshotへ保存する' do
    evidence = {
      source_provider: 'azure_structured',
      source_field_path: 'documents[0].fields.Items[0].Price',
      item_index: 0,
      provider_span_start: 10,
      provider_span_end: 19,
      source_text: '保存しない価格OCR全文'
    }
    candidates = Array.new(101) do |index|
      {
        candidate_id: "azure_items_#{index}_reference_pricing",
        item_index: index,
        validation_state: 'valid',
        rejection_reasons: [],
        reference_price: { amount: '498.123456', evidence: evidence.merge(item_index: index) },
        reference_quantity: {
          amount: '100',
          unit_code: 'gram',
          unit_status: 'known',
          origin: 'explicit',
          evidence: evidence.merge(item_index: index)
        },
        purchased_quantity: {
          amount: '342',
          unit_code: 'gram',
          unit_status: 'known',
          evidence: evidence.merge(item_index: index)
        },
        reference_price_tax_inclusion: 'gross',
        tax_inclusion_evidence: evidence.merge(item_index: index),
        printed_line_total: { amount: '1703', evidence: evidence.merge(item_index: index) },
        corroboration: {
          exact_amount: { numerator: '170316', denominator: '100' },
          projected_amount: 1_703,
          printed_line_total: '1703',
          rounding_matches: %w[floor half_up ceil invented]
        },
        raw_text: '保存しないitem OCR全文',
        source_text: '保存しないcandidate OCR全文',
        provider_raw_response: '保存しないprovider payload'
      }
    end

    snapshot = described_class.ocr_result_snapshot(
      success: true,
      candidates: { reference_pricing_candidates: candidates }
    )
    candidate = snapshot.dig('candidates', 'reference_pricing_candidates', 0)

    aggregate_failures do
      expect(snapshot.dig('candidates', 'reference_pricing_candidates').size).to eq(100)
      expect(snapshot.dig('candidate_counts', 'reference_pricing_candidates')).to eq(
        'actual_count' => 101,
        'snapshot_count' => 100
      )
      expect(snapshot.dig('truncated', 'reference_pricing_candidates')).to be(true)
      expect(candidate).to include(
        'candidate_id' => 'azure_items_0_reference_pricing',
        'item_index' => 0,
        'validation_state' => 'valid',
        'rejection_reasons' => [],
        'reference_price_tax_inclusion' => 'gross'
      )
      expect(candidate.dig('reference_price', 'amount')).to eq('498.123456')
      expect(candidate.dig('reference_quantity')).to include(
        'amount' => '100',
        'unit_code' => 'gram',
        'unit_status' => 'known',
        'origin' => 'explicit'
      )
      expect(candidate.dig('corroboration', 'rounding_matches')).to eq(%w[floor half_up ceil])
      expect(candidate.dig('reference_price', 'evidence').keys).to match_array(%w[
        source_provider
        source_field_path
        item_index
        provider_span_start
        provider_span_end
      ])
      expect(snapshot.to_json).not_to include(
        '保存しない価格OCR全文',
        '保存しないitem OCR全文',
        '保存しないcandidate OCR全文',
        '保存しないprovider payload',
        'source_text',
        'raw_text',
        'provider_raw_response'
      )
    end
  end

  it 'Azure line-group candidateをItems identityと混在させず構造evidenceだけ保存する' do
    line_evidence = {
      source_provider: 'azure_line_group',
      source_field_path: 'pages[0].lines[1]',
      provider_span_start: 19,
      provider_span_end: 22,
      string_index_type: 'textElements',
      item_index: 0,
      source_text: '保存しないline OCR全文',
      polygon: [ 20, 50, 122, 50, 122, 66, 20, 66 ],
      provider_raw_response: { 'private' => '保存しないprovider payload' }
    }
    candidate = {
      candidate_id: 'azure_line_group_p0_l1_l2_reference_pricing',
      source_kind: 'azure_line_group',
      page_index: 0,
      reference_line_index: 1,
      purchased_quantity_line_index: 2,
      string_index_type: 'textElements',
      item_index: 0,
      validation_state: 'valid',
      rejection_reasons: [],
      reference_price: { amount: '120', evidence: line_evidence },
      reference_quantity: {
        amount: '1',
        unit_code: 'liter',
        unit_status: 'known',
        origin: 'explicit',
        evidence: line_evidence.merge(provider_span_start: 24, provider_span_end: 27)
      },
      purchased_quantity: {
        amount: '2.5',
        unit_code: 'liter',
        unit_status: 'known',
        evidence: line_evidence.merge(
          source_field_path: 'pages[0].lines[2]',
          provider_span_start: 31,
          provider_span_end: 36
        )
      },
      reference_price_tax_inclusion: 'gross',
      tax_inclusion_evidence: line_evidence.merge(provider_span_start: 16, provider_span_end: 18),
      printed_line_total: nil,
      summary_total_corroboration: {
        exact_amount: { numerator: '300', denominator: '1' },
        projected_amount: 300,
        summary_total: '300',
        rounding_matches: %w[floor half_up ceil]
      },
      raw_text: '保存しないcandidate OCR全文',
      line_content: '保存しないline content',
      word_content: '保存しないword content',
      full_page_content: '保存しないfull page content',
      provider_raw_response: '保存しないprovider payload',
      private_filename: '/private/path/receipt.png',
      manifest_hash: '保存しないprivate hash'
    }

    snapshot = described_class.ocr_result_snapshot(
      success: true,
      candidates: { items: [], reference_pricing_candidates: [ candidate ] }
    )
    stored = snapshot.dig('candidates', 'reference_pricing_candidates', 0)

    aggregate_failures do
      expect(snapshot.dig('candidates', 'items')).to eq([])
      expect(stored).to include(
        'candidate_id' => 'azure_line_group_p0_l1_l2_reference_pricing',
        'source_kind' => 'azure_line_group',
        'page_index' => 0,
        'reference_line_index' => 1,
        'purchased_quantity_line_index' => 2,
        'string_index_type' => 'textElements',
        'validation_state' => 'valid',
        'rejection_reasons' => [],
        'reference_price_tax_inclusion' => 'gross'
      )
      expect(stored).not_to have_key('item_index')
      expect(stored.dig('reference_price', 'evidence')).to eq(
        'source_provider' => 'azure_line_group',
        'source_field_path' => 'pages[0].lines[1]',
        'provider_span_start' => 19,
        'provider_span_end' => 22,
        'string_index_type' => 'textElements'
      )
      expect(stored.dig('purchased_quantity', 'evidence', 'source_field_path')).to eq(
        'pages[0].lines[2]'
      )
      expect(stored.dig('reference_price').keys).to eq([ 'evidence' ])
      expect(stored.dig('reference_quantity').keys).to eq([ 'evidence' ])
      expect(stored.dig('purchased_quantity').keys).to eq([ 'evidence' ])
      expect(stored.dig('summary_total_corroboration')).to eq(
        'state' => 'matched',
        'rounding_matches' => %w[floor half_up ceil]
      )
      expect(snapshot.to_json).not_to include(
        'documents[0].fields.Items',
        'item_index',
        '保存しない',
        'source_text',
        'raw_text',
        'line_content',
        'word_content',
        'polygon',
        'full_page_content',
        'provider_raw_response',
        'private_filename',
        'manifest_hash',
        '/private/path'
      )
    end
  end

  it 'strict destination付きgross candidateだけをbounded typed adoption proposalへ分離する' do
    snapshot = described_class.ocr_result_snapshot(destination_ocr_result)
    proposal = snapshot.dig('adoption_proposals', 'reference_pricing')
    diagnostic = snapshot.dig('candidates', 'reference_pricing_candidates', 0)

    aggregate_failures do
      expect(snapshot['schema_version']).to eq('receipt_analysis_run_ocr_result_v1')
      expect(proposal).to include(
        'schema_version' => 'reference_pricing_adoption_proposal_v1',
        'creation_stage' => 'ocr_validation',
        'source_kind' => 'azure_line_group',
        'provider_model_id' => 'prebuilt-receipt',
        'provider_api_version' => '2024-11-30',
        'string_index_type' => 'textElements',
        'candidate_id' => 'azure_line_group_p0_l1_l2_reference_pricing',
        'validation_state' => 'valid',
        'validation_contract_version' => 'azure_line_group_v1',
        'analysis_profile_country_code' => 'JPN',
        'reference_price_tax_inclusion' => 'gross',
        'integrity_checksum' => match(/\A[0-9a-f]{64}\z/)
      )
      expect(proposal.dig('reference_price')).to include('amount' => '120')
      expect(proposal.dig('reference_quantity')).to include(
        'amount' => '1',
        'unit_code' => 'liter',
        'origin' => 'explicit'
      )
      expect(proposal.dig('purchased_quantity')).to include(
        'amount' => '2.5',
        'unit_code' => 'liter'
      )
      expect(proposal.dig('corroboration')).to eq(
        'state' => 'matched',
        'rounding_matches' => %w[floor half_up ceil]
      )
      expect(proposal.dig('destination', 'identity')).to eq(
        'azure_line_group_destination_p0_name_l1_s13_e19_ref_l1_qty_l2'
      )
      expect(proposal.dig('destination', 'evidence', 'word_spans').size).to eq(4)
      expect(proposal.dig('destination', 'evidence', 'tax_word_spans').size).to eq(2)
      expect(diagnostic).to include(
        'provider_model_id' => 'prebuilt-receipt',
        'provider_api_version' => '2024-11-30',
        'validation_contract_version' => 'azure_line_group_v1',
        'analysis_profile_country_code' => 'JPN'
      )
      expect(diagnostic.dig('destination_item_identity', 'identity')).to eq(
        proposal.dig('destination', 'identity')
      )
      expect(diagnostic.dig('reference_price').keys).to eq([ 'evidence' ])
      expect(JSON.generate(proposal).bytesize).to be <= 4096
      expect(proposal.to_json).not_to include(
        '検証品A01',
        'SYNTH-LAYOUT',
        'line_content',
        'word_content',
        'polygon',
        'provider_raw_response'
      )
    end
  end

  it 'structured Itemの計算方式候補をraw textと分離したtyped proposalへ保存する' do
    snapshot = described_class.ocr_result_snapshot(structured_count_ocr_result)
    proposals = snapshot.dig('adoption_proposals', 'item_calculation_modes')

    aggregate_failures do
      expect(proposals.size).to eq(4)
      expect(proposals).to all(include(
        'schema_version' => 'item_calculation_mode_proposal_set_v1',
        'source_provider' => 'azure_structured',
        'integrity_checksum' => match(/\A[0-9a-f]{64}\z/)
      ))
      expect(snapshot.dig('candidates', 'items', 0, 'ocr_item_identity')).to eq(
        proposals.first['item_identity']
      )
      expect(snapshot.dig('candidate_counts', 'item_calculation_mode_candidates')).to eq(
        'actual_count' => 4,
        'snapshot_count' => 4
      )
      expect(proposals.to_json).not_to include('ノート A5', 'raw_text', 'provider_raw_response')
    end
  end

  it 'structured Item proposalをretry用snapshotへexactに再sanitizeする' do
    initial = described_class.ocr_result_snapshot(structured_count_ocr_result)
    copied = described_class.ocr_result_snapshot(initial)

    aggregate_failures do
      expect(copied.dig('adoption_proposals', 'item_calculation_modes')).to eq(
        initial.dig('adoption_proposals', 'item_calculation_modes')
      )
      expect(copied.dig('candidate_counts', 'item_calculation_mode_candidates')).to eq(
        'actual_count' => 4,
        'snapshot_count' => 4
      )
      expect(copied.dig('truncated', 'item_calculation_mode_candidates')).to be(false)
    end
  end

  it '印字明細合計なしのcount proposalをJSON round-tripとretry再sanitizeで維持する' do
    initial = described_class.ocr_result_snapshot(structured_count_without_totals_ocr_result)
    stored = initial.dig('adoption_proposals', 'item_calculation_modes')
    copied = described_class.ocr_result_snapshot(JSON.parse(JSON.generate(initial)))
    rehydrated = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(copied)

    aggregate_failures do
      expect(stored).to be_present
      expect(stored).to all(satisfy do |proposal|
        proposal.fetch('options').pluck('pricing_source_kind') == [ 'count_unit_price' ] &&
          !proposal.key?('printed_line_total')
      end)
      expect(copied.dig('adoption_proposals', 'item_calculation_modes')).to eq(stored)
      expect(rehydrated.dig(:adoption_proposals, 'item_calculation_modes')).to eq(stored)
    end
  end

  it 'structured reference proposalをJSON round-tripとretry再sanitizeでexactに維持する' do
    initial = described_class.ocr_result_snapshot(structured_reference_ocr_result)
    stored = initial.dig('adoption_proposals', 'item_calculation_modes')
    copied = described_class.ocr_result_snapshot(JSON.parse(JSON.generate(initial)))
    rehydrated = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(copied)

    aggregate_failures do
      expect(stored.sole.fetch('options').pluck('pricing_source_kind')).to eq(
        %w[reference_quantity_price explicit_line_total]
      )
      expect(JSON.generate(stored.sole).bytesize).to be <= 4096
      expect(copied.dig('adoption_proposals', 'item_calculation_modes')).to eq(stored)
      expect(rehydrated.dig(:adoption_proposals, 'item_calculation_modes')).to eq(stored)
      expect(stored.to_json).not_to include('raw_text', 'provider_raw_response', 'polygon')
    end
  end

  it 'layout明細のbounded構造とexplicit-only proposalをsnapshotへ保存する' do
    snapshot = described_class.ocr_result_snapshot(item_layout_ocr_result)
    candidate = snapshot.dig('candidates', 'reference_pricing_candidates').sole
    proposal = snapshot.dig('adoption_proposals', 'item_calculation_modes').sole

    aggregate_failures do
      expect(snapshot.dig('candidates', 'reference_pricing_block_line_indexes')).to eq([ 1, 2, 3, 4 ])
      expect(snapshot.dig('candidates', 'items', 0, 'ocr_item_identity')).to start_with(
        'azure_item_layout_item_'
      )
      expect(candidate).to include(
        'candidate_id' => 'azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l4_reference_pricing',
        'source_kind' => 'azure_item_layout',
        'item_index' => 0,
        'page_index' => 0,
        'name_line_index' => 1,
        'reference_line_index' => 2,
        'reference_line_provider_span_start' => 26,
        'reference_line_provider_span_end' => 40,
        'purchased_quantity_line_indexes' => [ 3 ],
        'printed_total_line_index' => 4,
        'owned_line_indexes' => [ 1, 2, 3, 4 ],
        'validation_state' => 'valid'
      )
      expect(candidate.dig('reference_price', 'amount')).to eq('498')
      expect(candidate.dig('reference_price', 'evidence')).to include(
        'source_provider' => 'azure_item_layout',
        'source_field_path' => 'pages[0].lines[2]',
        'provider_span_start' => 29,
        'provider_span_end' => 32,
        'string_index_type' => 'textElements'
      )
      expect(proposal).to include(
        'source_provider' => 'azure_item_layout',
        'item_identity' => 'azure_item_layout_item_p0_name_l1_s16_e22_ref_l2_qty_l3_total_l4'
      )
      expect(proposal.fetch('options').pluck('pricing_source_kind')).to eq([ 'explicit_line_total' ])
      expect(snapshot.dig('adoption_proposals', 'reference_pricing')).to be_nil
      expect(snapshot.to_json).not_to include('polygon', 'word_content', 'provider_raw_response')
    end
  end

  it 'shared basis header候補を専用contractで保存し計算方式はexplicit-onlyに維持する' do
    result = shared_basis_diagnostic_ocr_result
    initial = described_class.ocr_result_snapshot(result)
    candidate = initial.dig('candidates', 'reference_pricing_candidates').sole
    proposals = initial.dig('adoption_proposals', 'item_calculation_modes')
    copied = described_class.ocr_result_snapshot(JSON.parse(JSON.generate(initial)))

    aggregate_failures do
      expect(candidate).to include(
        'validation_contract_version' => 'azure_item_layout_shared_basis_v1',
        'destination_kind' => 'azure_structured_item',
        'structured_item_index' => 0,
        'owned_line_indexes' => [ 0, 1, 2, 3, 4 ],
        'validation_state' => 'ambiguous',
        'rejection_reasons' => [ 'ambiguous_tax_inclusion' ],
        'reference_price_tax_inclusion' => 'unknown'
      )
      expect(candidate.dig('reference_quantity', 'evidence')).to include(
        'source_field_path' => 'pages[0].lines[0]',
        'line_index' => 0,
        'provider_span_start' => 0,
        'provider_span_end' => 4
      )
      expect(proposals.sole.fetch('options').pluck('pricing_source_kind')).to eq([ 'explicit_line_total' ])
      expect(proposals.sum do |proposal|
        proposal.fetch('options').count { |option| option['pricing_source_kind'] == 'reference_quantity_price' }
      end).to eq(0)
      expect(initial.dig('adoption_proposals', 'reference_pricing')).to be_nil
      expect(copied.dig('candidates', 'reference_pricing_candidates').sole).to eq(candidate)
      expect(copied.dig('adoption_proposals', 'item_calculation_modes')).to eq(proposals)
    end
  end

  it 'shared basis header候補のidentity・header evidence・row ownership改変を候補ごと破棄する' do
    mutations = {
      unknown_contract: ->(candidate) { candidate[:validation_contract_version] = 'unknown_v1' },
      wrong_identity: ->(candidate) { candidate[:item_identity] = 'azure_structured_item_i1_s16_e55' },
      wrong_candidate_tuple: ->(candidate) {
        candidate[:candidate_id] = 'azure_item_layout_p0_name_l1_ref_l3_qty_l4_total_l5_reference_pricing'
      },
      wrong_header_path: ->(candidate) {
        candidate.dig(:reference_quantity, :evidence)[:source_field_path] = 'pages[0].lines[1]'
      },
      header_after_name: ->(candidate) {
        candidate.dig(:reference_quantity, :evidence).merge!(
          source_field_path: 'pages[0].lines[5]',
          line_index: 5,
          provider_span_start: 56,
          provider_span_end: 60
        )
        candidate[:owned_line_indexes] = [ 1, 2, 3, 4, 5 ]
      },
      header_inside_parent: ->(candidate) {
        candidate.dig(:reference_quantity, :evidence).merge!(
          provider_span_start: 17,
          provider_span_end: 20
        )
      },
      missing_header_ownership: ->(candidate) { candidate[:owned_line_indexes] = [ 1, 2, 3, 4 ] },
      noncontiguous_row: ->(candidate) { candidate[:owned_line_indexes] = [ 0, 1, 2, 4 ] },
      extra_owned_line: ->(candidate) { candidate[:owned_line_indexes] = [ 0, 1, 2, 3, 4, 5 ] },
      reference_outside_parent: ->(candidate) {
        candidate.dig(:reference_price, :evidence).merge!(provider_span_start: 2, provider_span_end: 5)
      },
      dimension_mismatch: ->(candidate) {
        candidate.dig(:purchased_quantity)[:unit_code] = 'milliliter'
      },
      premature_valid_state: ->(candidate) {
        candidate.merge!(validation_state: 'valid', rejection_reasons: [])
      }
    }

    snapshots = mutations.transform_values do |mutation|
      result = shared_basis_diagnostic_ocr_result
      mutation.call(result.dig(:candidates, :reference_pricing_candidates).sole)
      described_class.ocr_result_snapshot(result)
    end

    aggregate_failures do
      snapshots.each do |name, snapshot|
        expect(snapshot.dig('candidates', 'reference_pricing_candidates')).to eq([]), name.to_s
      end
    end
  end

  it 'shared basis headerと最初のrowの間を最大3 context lineに制限する' do
    maximum = shared_basis_diagnostic_ocr_result
    move_shared_basis_row_indexes!(maximum, name_line_index: 4)
    overflow = shared_basis_diagnostic_ocr_result
    move_shared_basis_row_indexes!(overflow, name_line_index: 5)

    maximum_snapshot = described_class.ocr_result_snapshot(maximum)
    overflow_snapshot = described_class.ocr_result_snapshot(overflow)

    aggregate_failures do
      expect(maximum_snapshot.dig('candidates', 'reference_pricing_candidates').size).to eq(1)
      expect(overflow_snapshot.dig('candidates', 'reference_pricing_candidates')).to eq([])
    end
  end

  it 'single-item gross summaryをitem block外のbounded evidenceとしてexactに保存する' do
    result = single_item_gross_summary_ocr_result
    snapshot = described_class.ocr_result_snapshot(result)
    candidate = snapshot.dig('candidates', 'reference_pricing_candidates').sole
    proposal = snapshot.dig('adoption_proposals', 'item_calculation_modes').sole
    tax_evidence = candidate.fetch('tax_inclusion_evidence')
    copied = described_class.ocr_result_snapshot(JSON.parse(JSON.generate(snapshot)))

    aggregate_failures do
      expect(candidate).to include(
        'item_identity' => 'azure_structured_item_i0_s16_e38',
        'destination_kind' => 'azure_structured_item',
        'structured_item_index' => 0,
        'reference_price_tax_inclusion' => 'gross'
      )
      expect(tax_evidence).to eq(
        'kind' => 'single_item_receipt_gross_summary',
        'string_index_type' => 'textElements',
        'policy_contract_version' => 'reference_pricing_single_item_gross_summary_policy_v1',
        'summary_total' => {
          'source_provider' => 'azure_item_layout',
          'source_field_path' => 'pages[0].lines[5]',
          'page_index' => 0,
          'line_index' => 5,
          'string_index_type' => 'textElements',
          'provider_span_start' => 70,
          'provider_span_end' => 80,
          'amount' => 1703
        },
        'gross_tax_target' => {
          'source_provider' => 'azure_item_layout',
          'source_field_path' => 'pages[0].lines[6]',
          'page_index' => 0,
          'line_index' => 6,
          'string_index_type' => 'textElements',
          'provider_span_start' => 82,
          'provider_span_end' => 105,
          'rate' => '0.1',
          'net_amount' => 1549,
          'tax_amount' => 154,
          'gross_amount' => 1703
        }
      )
      expect(proposal).to include(
        'source_provider' => 'azure_item_layout',
        'destination_kind' => 'azure_structured_item',
        'item_identity' => 'azure_structured_item_i0_s16_e38'
      )
      expect(proposal.fetch('options').pluck('pricing_source_kind')).to eq(%w[
        reference_quantity_price
        explicit_line_total
      ])
      expect(proposal.dig('options', 0, 'evidence', 'tax_inclusion')).to eq(tax_evidence)
      expect(copied.dig('candidates', 'reference_pricing_candidates').sole).to eq(candidate)
      expect(copied.dig('adoption_proposals', 'item_calculation_modes').sole).to eq(proposal)
      expect([ tax_evidence, proposal ].to_json).not_to include(
        'raw_text',
        'product_name',
        'store_name',
        'polygon'
      )
    end
  end

  it 'native Itemの内税根拠をbounded proposalへ保存しretryでexactに再検証する' do
    initial = described_class.ocr_result_snapshot(single_structured_item_inner_tax_ocr_result)
    candidate = initial.dig('candidates', 'reference_pricing_candidates').sole
    proposal = initial.dig('adoption_proposals', 'item_calculation_modes').sole
    tax_evidence = candidate.fetch('tax_inclusion_evidence')
    copied = described_class.ocr_result_snapshot(JSON.parse(JSON.generate(initial)))
    rehydrated = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(copied)

    aggregate_failures do
      expect(tax_evidence).to include(
        'kind' => 'single_item_receipt_inner_tax_summary',
        'policy_contract_version' => 'reference_pricing_single_structured_item_gross_policy_v1'
      )
      expect(tax_evidence.fetch('item_parent')).to include(
        'source_field_path' => 'documents[0].fields.Items[0]',
        'item_index' => 0
      )
      expect(tax_evidence.fetch('tax_detail_parent')).to include(
        'source_field_path' => 'documents[0].fields.TaxDetails[0]',
        'tax_detail_index' => 0
      )
      expect(tax_evidence.dig('tax_amount', 'amount')).to eq(154)
      expect(tax_evidence.dig('document_tax_total', 'amount')).to eq(154)
      expect(tax_evidence.dig('summary_total', 'amount')).to eq(1703)
      expect(proposal.fetch('options').pluck('pricing_source_kind')).to eq(%w[
        reference_quantity_price
        explicit_line_total
      ])
      expect(proposal.dig('options', 0, 'evidence', 'tax_inclusion')).to eq(tax_evidence)
      expect(copied.dig('adoption_proposals', 'item_calculation_modes').sole).to eq(proposal)
      expect(rehydrated.dig(:adoption_proposals, 'item_calculation_modes').sole).to eq(proposal)
      expect([ tax_evidence, proposal ].to_json).not_to include(
        'raw_text',
        'product_name',
        'store_name',
        'polygon'
      )
    end
  end

  it 'Quantity内のimplicit per-unit単位evidenceをbounded candidate snapshotへ保存しretryで再検証する' do
    result = single_structured_item_inner_tax_ocr_result
    reference = result.dig(:candidates, :reference_pricing_candidates).sole
    reference[:reference_price][:amount] = '1703'
    reference[:reference_quantity].merge!(
      amount: '1',
      origin: 'implicit_per_unit',
      evidence: reference[:reference_quantity][:evidence].merge(
        source_field_path: 'documents[0].fields.Items[0].Quantity'
      )
    )
    reference[:purchased_quantity][:amount] = '1'
    reference[:corroboration] = {
      exact_amount: { numerator: '1703', denominator: '1' },
      projected_amount: 1703,
      printed_line_total: '1703',
      rounding_matches: %w[floor half_up ceil]
    }

    initial = described_class.ocr_result_snapshot(result)
    copied = described_class.ocr_result_snapshot(JSON.parse(JSON.generate(initial)))
    stored = initial.dig('candidates', 'reference_pricing_candidates').sole

    aggregate_failures do
      expect(stored.dig('reference_quantity', 'evidence', 'source_field_path')).to eq(
        'documents[0].fields.Items[0].Quantity'
      )
      expect(stored.dig('tax_inclusion_evidence', 'kind')).to eq(
        'single_item_receipt_inner_tax_summary'
      )
      expect(copied.dig('candidates', 'reference_pricing_candidates').sole).to eq(stored)
      expect(stored.to_json).not_to include('raw_text', 'provider_raw_response', 'valueString')
    end
  end

  it 'native Item内税根拠のunknown field・partial overlap・amount不一致を部分保存しない' do
    unknown = single_structured_item_inner_tax_ocr_result
    unknown.dig(
      :candidates, :reference_pricing_candidates, 0, :tax_inclusion_evidence
    )[:raw_text] = '保存禁止'
    partial_overlap = single_structured_item_inner_tax_ocr_result
    partial_overlap.dig(
      :candidates, :reference_pricing_candidates, 0, :tax_inclusion_evidence, :document_tax_total
    ).merge!(provider_span_start: 37, provider_span_end: 40)
    mismatched = single_structured_item_inner_tax_ocr_result
    mismatched.dig(
      :candidates, :reference_pricing_candidates, 0, :tax_inclusion_evidence, :summary_total
    )[:amount] = 1702

    [ unknown, partial_overlap, mismatched ].each do |result|
      snapshot = described_class.ocr_result_snapshot(result)

      aggregate_failures do
        expect(snapshot.dig('adoption_proposals', 'item_calculation_modes')).to be_nil
        expect(snapshot.dig('candidates', 'reference_pricing_candidates').to_json).not_to include(
          '保存禁止',
          'raw_text'
        )
      end
    end
  end

  it 'single-item gross summaryのunknown・block overlap・amount不一致をproposalへ部分保存しない' do
    unknown = single_item_gross_summary_ocr_result
    unknown.dig(
      :candidates,
      :reference_pricing_candidates,
      0,
      :tax_inclusion_evidence,
      :summary_total
    )[:raw_text] = '保存禁止'
    overlapping = single_item_gross_summary_ocr_result
    overlapping.dig(
      :candidates,
      :reference_pricing_candidates,
      0,
      :tax_inclusion_evidence,
      :summary_total
    ).merge!(provider_span_start: 50, provider_span_end: 60)
    mismatched = single_item_gross_summary_ocr_result
    mismatched.dig(
      :candidates,
      :reference_pricing_candidates,
      0,
      :tax_inclusion_evidence,
      :gross_tax_target
    )[:gross_amount] = 1702
    line_over_bound = single_item_gross_summary_ocr_result
    line_over_bound.dig(
      :candidates,
      :reference_pricing_candidates,
      0,
      :tax_inclusion_evidence,
      :summary_total
    ).merge!(source_field_path: 'pages[0].lines[150]', line_index: 150)
    overprecision_rate = single_item_gross_summary_ocr_result
    target = overprecision_rate.dig(
      :candidates,
      :reference_pricing_candidates,
      0,
      :tax_inclusion_evidence,
      :gross_tax_target
    )
    target.merge!(rate: '0.1234567', net_amount: 1516, tax_amount: 187)
    overprecision_rate.dig(:candidates)[:tax_amount] = 187
    structured_parent_overlap = single_item_gross_summary_ocr_result
    expanded_identity = 'azure_structured_item_i0_s16_e80'
    structured_parent_overlap.dig(:candidates, :items, 0)[:ocr_item_identity] = expanded_identity
    structured_parent_overlap.dig(:candidates, :reference_pricing_candidates, 0)[:item_identity] = expanded_identity
    structured_parent_overlap.dig(:candidates, :item_calculation_mode_candidates, 0)[:item_identity] = expanded_identity
    missing_line_span = single_item_gross_summary_ocr_result
    missing_line_span.dig(:candidates, :reference_pricing_candidates, 0)
      .delete(:reference_line_provider_span_start)

    aggregate_failures do
      [
        unknown,
        overlapping,
        mismatched,
        line_over_bound,
        overprecision_rate,
        structured_parent_overlap,
        missing_line_span
      ].each do |result|
        snapshot = described_class.ocr_result_snapshot(result)
        expect(snapshot.dig('adoption_proposals', 'item_calculation_modes')).to be_nil
        expect(snapshot.dig('candidates', 'reference_pricing_candidates').to_json)
          .not_to include('保存禁止', 'raw_text')
      end
    end
  end

  it 'layout explicit proposalをJSON round-tripでexactに維持し不正なblock indexをfail-closedにする' do
    initial = described_class.ocr_result_snapshot(item_layout_ocr_result)
    copied = described_class.ocr_result_snapshot(JSON.parse(JSON.generate(initial)))
    malformed = item_layout_ocr_result.deep_dup
    malformed[:candidates][:reference_pricing_block_line_indexes] = [ -1, 2, 3, 151 ]
    malformed_snapshot = described_class.ocr_result_snapshot(malformed)

    aggregate_failures do
      expect(copied.dig('adoption_proposals', 'item_calculation_modes')).to eq(
        initial.dig('adoption_proposals', 'item_calculation_modes')
      )
      expect(copied.dig('candidates', 'reference_pricing_candidates')).to eq(
        initial.dig('candidates', 'reference_pricing_candidates')
      )
      expect(malformed_snapshot.dig('candidates', 'reference_pricing_block_line_indexes')).to eq([])
    end
  end

  it 'adjustment-only provider Itemをdestinationから除外し通常Itemのproposalを維持する' do
    result = discount_heavy_ocr_result
    snapshot = described_class.ocr_result_snapshot(result)

    aggregate_failures do
      expect(result.dig(:candidates, :item_calculation_mode_candidates).map do |candidate|
        candidate[:item_index]
      end).to eq([ 0, 1, 2 ])
      expect(snapshot.dig('adoption_proposals', 'item_calculation_modes').map do |proposal|
        proposal['item_index']
      end).to eq([ 0, 1, 2 ])
      expect(result.dig(:candidates, :adjustment_candidates)).to be_present
    end
  end

  it 'source item truncationを隠さずproposal全体をfail closedに除外する' do
    result = structured_count_ocr_result.deep_dup
    result[:candidates][:item_calculation_mode_source_truncated] = true

    snapshot = described_class.ocr_result_snapshot(result)

    aggregate_failures do
      expect(snapshot.dig('truncated', 'item_calculation_mode_candidates')).to be(true)
      expect(snapshot.dig('adoption_proposals', 'item_calculation_modes')).to be_nil
      expect(snapshot.dig('candidate_counts', 'item_calculation_mode_candidates')).to eq(
        'actual_count' => 4,
        'snapshot_count' => 0
      )
    end

    copied = described_class.ocr_result_snapshot(snapshot)
    aggregate_failures do
      expect(copied.dig('truncated', 'item_calculation_mode_candidates')).to be(true)
      expect(copied.dig('candidate_counts', 'item_calculation_mode_candidates')).to eq(
        'actual_count' => 4,
        'snapshot_count' => 0
      )
      expect(copied.dig('adoption_proposals', 'item_calculation_modes')).to be_nil
    end
  end

  it '上限超過のactual candidate countをretry再sanitizeでも維持する' do
    initial = {
      'schema_version' => described_class::OCR_RESULT_SCHEMA_VERSION,
      'success' => true,
      'candidates' => { 'items' => [] },
      'candidate_counts' => {
        'items' => { 'actual_count' => 0, 'snapshot_count' => 0 },
        'item_calculation_mode_candidates' => { 'actual_count' => 101, 'snapshot_count' => 0 }
      },
      'truncated' => { 'items' => false, 'item_calculation_mode_candidates' => true }
    }

    copied = described_class.ocr_result_snapshot(initial)

    aggregate_failures do
      expect(copied.dig('candidate_counts', 'item_calculation_mode_candidates')).to eq(
        'actual_count' => 101,
        'snapshot_count' => 0
      )
      expect(copied.dig('truncated', 'item_calculation_mode_candidates')).to be(true)
      expect(copied.dig('adoption_proposals', 'item_calculation_modes')).to be_nil
    end
  end

  it 'reference candidateの上限超過countとtruncationをretry再sanitizeでも維持する' do
    initial = {
      'schema_version' => described_class::OCR_RESULT_SCHEMA_VERSION,
      'success' => true,
      'candidates' => {
        'items' => [],
        'reference_pricing_candidates' => Array.new(100) do |index|
          { 'candidate_id' => "azure_items_#{index}_reference_pricing" }
        end
      },
      'candidate_counts' => {
        'items' => { 'actual_count' => 0, 'snapshot_count' => 0 },
        'reference_pricing_candidates' => { 'actual_count' => 101, 'snapshot_count' => 100 },
        'item_calculation_mode_candidates' => { 'actual_count' => 0, 'snapshot_count' => 0 }
      },
      'truncated' => {
        'items' => false,
        'reference_pricing_candidates' => true,
        'item_calculation_mode_candidates' => false
      }
    }

    copied = described_class.ocr_result_snapshot(initial)

    aggregate_failures do
      expect(copied.dig('candidate_counts', 'reference_pricing_candidates')).to eq(
        'actual_count' => 101,
        'snapshot_count' => 100
      )
      expect(copied.dig('truncated', 'reference_pricing_candidates')).to be(true)
      expect(copied.dig('adoption_proposals', 'item_calculation_modes')).to be_nil
    end
  end

  it 'stored metadataが未truncateを主張してもreference candidate配列の上限超過を隠さない' do
    initial = {
      'schema_version' => described_class::OCR_RESULT_SCHEMA_VERSION,
      'success' => true,
      'candidates' => {
        'items' => [],
        'reference_pricing_candidates' => Array.new(101) do |index|
          { 'candidate_id' => "azure_items_#{index}_reference_pricing" }
        end
      },
      'candidate_counts' => {
        'items' => { 'actual_count' => 0, 'snapshot_count' => 0 },
        'reference_pricing_candidates' => { 'actual_count' => 100, 'snapshot_count' => 100 },
        'item_calculation_mode_candidates' => { 'actual_count' => 0, 'snapshot_count' => 0 }
      },
      'truncated' => {
        'items' => false,
        'reference_pricing_candidates' => false,
        'item_calculation_mode_candidates' => false
      }
    }

    copied = described_class.ocr_result_snapshot(initial)

    aggregate_failures do
      expect(copied.dig('candidate_counts', 'reference_pricing_candidates')).to eq(
        'actual_count' => 0,
        'snapshot_count' => 0
      )
      expect(copied.dig('truncated', 'reference_pricing_candidates')).to be(true)
      expect(copied.dig('adoption_proposals', 'item_calculation_modes')).to be_nil
    end
  end

  it '自動採用設定OFFでもcandidate extractionとtyped proposal保存を継続する' do
    create(
      :system_setting,
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      value: SystemSettings.stored_value(false)
    )

    expect {
      snapshot = described_class.ocr_result_snapshot(destination_ocr_result)

      expect(snapshot.dig('adoption_proposals', 'reference_pricing')).to be_present
    }.not_to change(ReceiptItem, :count)
  end

  it 'gross corroboration・single candidate・lossless case lineのどれかを欠くとproposal全体だけを除外する' do
    net = destination_ocr_result.deep_dup
    net.dig(:candidates, :reference_pricing_candidates, 0)[:reference_price_tax_inclusion] = 'net'

    uncorroborated = destination_ocr_result.deep_dup
    uncorroborated.dig(:candidates, :reference_pricing_candidates, 0).delete(:summary_total_corroboration)

    multiple = destination_ocr_result.deep_dup
    multiple.dig(:candidates, :reference_pricing_candidates) <<
      multiple.dig(:candidates, :reference_pricing_candidates, 0).deep_dup

    truncated_line = destination_ocr_result.deep_dup
    truncated_line[:case_preserved_lines][1] = 'x' * 600

    truncated_purchased_line = destination_ocr_result.deep_dup
    truncated_purchased_line[:case_preserved_lines][2] = '計量 2.5 L ' + ('x' * 600)

    [ net, uncorroborated, multiple, truncated_line, truncated_purchased_line ].each do |ocr_result|
      snapshot = described_class.ocr_result_snapshot(ocr_result)

      aggregate_failures do
        expect(snapshot).not_to have_key('adoption_proposals')
        expect(snapshot.dig('candidates', 'reference_pricing_candidates')).to be_present
      end
    end
  end

  it 'stored proposalをretry用snapshotへexactに再sanitizeし改変proposalだけfail closedに除外する' do
    initial = described_class.ocr_result_snapshot(destination_ocr_result)
    copied = described_class.ocr_result_snapshot(initial)
    tampered = initial.deep_dup
    tampered.dig('adoption_proposals', 'reference_pricing')['unknown'] = 'not-allowed'
    rejected = described_class.ocr_result_snapshot(tampered)

    aggregate_failures do
      expect(copied.dig('adoption_proposals', 'reference_pricing')).to eq(
        initial.dig('adoption_proposals', 'reference_pricing')
      )
      expect(rejected).not_to have_key('adoption_proposals')
      expect(rejected.dig('candidates', 'reference_pricing_candidates')).to be_present
    end
  end

  it 'Azure line-group candidateのItems path混入をsnapshotへ保存しない' do
    snapshot = described_class.ocr_result_snapshot(
      success: true,
      candidates: {
        reference_pricing_candidates: [
          {
            candidate_id: 'azure_line_group_p0_l1_l2_reference_pricing',
            source_kind: 'azure_line_group',
            page_index: 0,
            reference_line_index: 1,
            purchased_quantity_line_index: 2,
            string_index_type: 'textElements',
            validation_state: 'valid',
            rejection_reasons: [],
            reference_price: {
              amount: '120',
              evidence: {
                source_provider: 'azure_line_group',
                source_field_path: 'documents[0].fields.Items[0].Price',
                item_index: 0,
                provider_span_start: 19,
                provider_span_end: 22,
                string_index_type: 'textElements'
              }
            }
          }
        ]
      }
    )
    expect(snapshot.dig('candidates', 'reference_pricing_candidates')).to eq([])
    expect(snapshot.to_json).not_to include('documents[0].fields.Items')
  end

  it 'Azure line-group candidateのidentityとline pathが一致しなければ候補全体を除外する' do
    base_evidence = {
      source_provider: 'azure_line_group',
      source_field_path: 'pages[0].lines[1]',
      provider_span_start: 10,
      provider_span_end: 12,
      string_index_type: 'textElements'
    }
    candidate = {
      candidate_id: 'azure_line_group_p0_l1_l2_reference_pricing',
      source_kind: 'azure_line_group',
      page_index: 0,
      reference_line_index: 1,
      purchased_quantity_line_index: 2,
      string_index_type: 'textElements',
      validation_state: 'valid',
      rejection_reasons: [],
      reference_price: { amount: '120', evidence: base_evidence },
      reference_quantity: { amount: '1', evidence: base_evidence },
      purchased_quantity: {
        amount: '2.5',
        evidence: base_evidence.merge(source_field_path: 'pages[0].lines[2]')
      },
      reference_price_tax_inclusion: 'gross',
      tax_inclusion_evidence: base_evidence
    }

    mismatches = [
      candidate.deep_merge(reference_price: { evidence: { source_field_path: 'pages[0].lines[9]' } }),
      candidate.merge(purchased_quantity_line_index: 3),
      candidate.merge(candidate_id: 'azure_line_group_p0_l8_l9_reference_pricing'),
      candidate.deep_merge(purchased_quantity: { evidence: { string_index_type: 'utf16CodeUnit' } }),
      candidate.merge(printed_line_total: { amount: '999', evidence: base_evidence }),
      candidate.merge(
        corroboration: {
          exact_amount: { numerator: '999', denominator: '1' },
          projected_amount: 999,
          printed_line_total: '999',
          rounding_matches: %w[floor]
        }
      ),
      candidate.except(:reference_price_tax_inclusion),
      candidate.merge(reference_price_tax_inclusion: 'unknown'),
      candidate.deep_merge(
        candidate_id: 'azure_line_group_p1_l1_l2_reference_pricing',
        page_index: 1,
        reference_price: { evidence: { source_field_path: 'pages[1].lines[1]' } },
        reference_quantity: { evidence: { source_field_path: 'pages[1].lines[1]' } },
        purchased_quantity: { evidence: { source_field_path: 'pages[1].lines[2]' } },
        tax_inclusion_evidence: { source_field_path: 'pages[1].lines[1]' }
      )
    ]

    mismatches.each do |mismatch|
      snapshot = described_class.ocr_result_snapshot(
        success: true,
        candidates: { reference_pricing_candidates: [ mismatch ] }
      )

      expect(snapshot.dig('candidates', 'reference_pricing_candidates')).to eq([])
    end
  end

  it 'reference pricing candidateの未知enumと不正型をfail closedに除外する' do
    snapshot = described_class.ocr_result_snapshot(
      success: true,
      candidates: {
        reference_pricing_candidates: [
          {
            candidate_id: 'rpc-invalid',
            item_index: 'not-an-index',
            validation_state: 'invented',
            rejection_reasons: [ 'invented', 'missing_reference_price' ],
            reference_price: { amount: {}, evidence: { item_index: 'bad' } },
            reference_quantity: {
              amount: [],
              unit_code: 'invented',
              unit_status: 'invented',
              origin: 'invented',
              evidence: { provider_span_start: -1, provider_span_end: 'bad' }
            },
            reference_price_tax_inclusion: 'invented',
            corroboration: {
              exact_amount: { numerator: {}, denominator: [] },
              projected_amount: '1703',
              rounding_matches: [ 'invented', 'floor' ]
            }
          }
        ]
      }
    )
    candidate = snapshot.dig('candidates', 'reference_pricing_candidates', 0)

    expect(candidate).to eq(
      'rejection_reasons' => [ 'missing_reference_price' ],
      'corroboration' => { 'rounding_matches' => [ 'floor' ] }
    )
  end

  it 'reference pricing candidateのunknown unit rawだけを64-byte上限で保存する' do
    snapshot = described_class.ocr_result_snapshot(
      success: true,
      candidates: {
        reference_pricing_candidates: [
          {
            candidate_id: 'azure_items_0_reference_pricing',
            item_index: 0,
            validation_state: 'unsupported',
            rejection_reasons: %w[unsupported_reference_unit unsupported_purchased_unit],
            reference_quantity: {
              amount: '100',
              unit_code: nil,
              unit_status: 'unknown',
              unit_raw: '未知単位' * 100,
              source_text: '保存しないreference unit周辺OCR全文'
            },
            purchased_quantity: {
              amount: '2',
              unit_code: nil,
              unit_status: 'unknown',
              unit_raw: '杯',
              source_text: '保存しないpurchased unit周辺OCR全文'
            }
          }
        ]
      }
    )
    candidate = snapshot.dig('candidates', 'reference_pricing_candidates', 0)

    aggregate_failures do
      expect(candidate.dig('reference_quantity', 'unit_raw').bytesize).to be <= 64
      expect(candidate.dig('purchased_quantity', 'unit_raw')).to eq('杯')
      expect(snapshot.to_json).not_to include(
        '保存しないreference unit周辺OCR全文',
        '保存しないpurchased unit周辺OCR全文',
        'source_text'
      )
    end
  end

  it 'reference pricing candidateのknown/blank unit rawと非文字列rawを保存しない' do
    candidates = [
      {
        candidate_id: 'azure_items_0_reference_pricing',
        item_index: 0,
        validation_state: 'valid',
        rejection_reasons: [],
        reference_quantity: {
          amount: '100', unit_code: 'gram', unit_status: 'known', unit_raw: 'g'
        },
        purchased_quantity: {
          amount: '2', unit_code: 'each', unit_status: 'blank', unit_raw: ''
        }
      },
      {
        candidate_id: 'azure_items_1_reference_pricing',
        item_index: 1,
        validation_state: 'unsupported',
        rejection_reasons: [ 'unsupported_reference_unit' ],
        reference_quantity: {
          amount: '100', unit_code: nil, unit_status: 'unknown', unit_raw: { raw: '保存しない' }
        }
      }
    ]
    snapshot = described_class.ocr_result_snapshot(
      success: true,
      candidates: { reference_pricing_candidates: candidates }
    )
    stored = snapshot.dig('candidates', 'reference_pricing_candidates')

    aggregate_failures do
      expect(stored.dig(0, 'reference_quantity')).not_to have_key('unit_raw')
      expect(stored.dig(0, 'purchased_quantity')).not_to have_key('unit_raw')
      expect(stored.dig(1, 'reference_quantity')).not_to have_key('unit_raw')
      expect(snapshot.to_json).not_to include('保存しない')
    end
  end

  it 'reference pricing candidateのindex・provider span・projected amountを固定上限まで保存する' do
    snapshot = described_class.ocr_result_snapshot(
      success: true,
      candidates: {
        reference_pricing_candidates: [
          {
            candidate_id: 'azure_items_99_reference_pricing',
            item_index: 99,
            validation_state: 'valid',
            rejection_reasons: [],
            reference_price: {
              amount: '1',
              evidence: {
                source_provider: 'azure_structured',
                source_field_path: 'documents[0].fields.Items[99].Price',
                item_index: 99,
                provider_span_start: 9_999_999,
                provider_span_end: 10_000_000
              }
            },
            corroboration: {
              projected_amount: 999_999_999,
              rounding_matches: []
            }
          }
        ]
      }
    )
    candidate = snapshot.dig('candidates', 'reference_pricing_candidates', 0)

    aggregate_failures do
      expect(candidate['item_index']).to eq(99)
      expect(candidate.dig('reference_price', 'evidence')).to include(
        'item_index' => 99,
        'provider_span_start' => 9_999_999,
        'provider_span_end' => 10_000_000
      )
      expect(candidate.dig('corroboration', 'projected_amount')).to eq(999_999_999)
    end
  end

  it 'reference pricing candidateの上限超過・巨大Integerをsnapshotから除外する' do
    huge_integer = 10**1_000
    snapshot = described_class.ocr_result_snapshot(
      success: true,
      candidates: {
        reference_pricing_candidates: [
          {
            candidate_id: 'azure_items_0_reference_pricing',
            item_index: 100,
            validation_state: 'valid',
            rejection_reasons: [],
            reference_price: {
              amount: '1',
              evidence: {
                source_provider: 'azure_structured',
                source_field_path: 'documents[0].fields.Items[0].Price',
                item_index: huge_integer,
                provider_span_start: 10_000_001,
                provider_span_end: huge_integer
              }
            },
            corroboration: {
              projected_amount: huge_integer,
              rounding_matches: []
            }
          }
        ]
      }
    )
    candidate = snapshot.dig('candidates', 'reference_pricing_candidates', 0)
    evidence = candidate.dig('reference_price', 'evidence')

    aggregate_failures do
      expect(candidate).not_to have_key('item_index')
      expect(evidence).not_to have_key('item_index')
      expect(evidence).not_to have_key('provider_span_start')
      expect(evidence).not_to have_key('provider_span_end')
      expect(candidate.dig('corroboration')).not_to have_key('projected_amount')
      expect(snapshot.to_json).not_to include(huge_integer.to_s)
    end
  end

  it 'invalid UTF-8のcandidate bounded stringを例外なくsnapshotから除外する' do
    invalid_utf8 = "\xFF".b.force_encoding(Encoding::UTF_8)
    snapshot = nil

    expect do
      snapshot = described_class.ocr_result_snapshot(
        success: true,
        candidates: {
          reference_pricing_candidates: [
            {
              candidate_id: invalid_utf8,
              item_index: 0,
              validation_state: 'unsupported',
              rejection_reasons: [ 'invalid_reference_price' ],
              reference_price: {
                amount: invalid_utf8,
                evidence: {
                  source_provider: 'azure_structured',
                  source_field_path: invalid_utf8,
                  item_index: 0,
                  provider_span_start: 0,
                  provider_span_end: 1
                }
              }
            }
          ]
        }
      )
    end.not_to raise_error

    candidate = snapshot.dig('candidates', 'reference_pricing_candidates', 0)

    aggregate_failures do
      expect(candidate).not_to have_key('candidate_id')
      expect(candidate.dig('reference_price')).not_to have_key('amount')
      expect(candidate.dig('reference_price', 'evidence')).not_to have_key('source_field_path')
      expect { snapshot.to_json }.not_to raise_error
    end
  end

  it 'invalid UTF-8と制御文字をOCR item・candidateのunknown unit rawから除外する' do
    invalid_utf8 = "\xFF".b.force_encoding(Encoding::UTF_8)
    snapshot = described_class.ocr_result_snapshot(
      success: true,
      candidates: {
        items: [
          { quantity_unit_status: 'unknown', quantity_unit_raw: "g\0" },
          { quantity_unit_status: 'unknown', quantity_unit_raw: invalid_utf8 }
        ],
        reference_pricing_candidates: [
          {
            candidate_id: 'azure_items_0_reference_pricing',
            item_index: 0,
            validation_state: 'unsupported',
            rejection_reasons: %w[unsupported_reference_unit unsupported_purchased_unit],
            reference_quantity: {
              amount: '1', unit_status: 'unknown', unit_raw: "杯\n"
            },
            purchased_quantity: {
              amount: '1', unit_status: 'unknown', unit_raw: invalid_utf8
            }
          }
        ]
      }
    )
    items = snapshot.dig('candidates', 'items')
    candidate = snapshot.dig('candidates', 'reference_pricing_candidates', 0)

    aggregate_failures do
      expect(items).to all(satisfy { |item| !item.key?('quantity_unit_raw') })
      expect(candidate.dig('reference_quantity')).not_to have_key('unit_raw')
      expect(candidate.dig('purchased_quantity')).not_to have_key('unit_raw')
      expect { snapshot.to_json }.not_to raise_error
      expect(snapshot.to_json).not_to include("\u0000", "\n")
    end
  end
end
