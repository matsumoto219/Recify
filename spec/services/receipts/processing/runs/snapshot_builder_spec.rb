require 'rails_helper'

RSpec.describe Receipts::Processing::Runs::SnapshotBuilder do
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
