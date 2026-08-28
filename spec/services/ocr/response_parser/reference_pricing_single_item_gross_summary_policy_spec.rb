require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ReferencePricingSingleItemGrossSummaryPolicy do
  ITEM_LINE_TOTAL_LIMIT = 999_999_999

  def evidence(line_index, span_start, span_end)
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

  def candidate
    {
      candidate_id: 'azure_item_layout_p0_name_l1_ref_l2_qty_l3_total_l4_reference_pricing',
      item_identity: 'azure_structured_item_i0_s10_e56',
      source_kind: 'azure_item_layout',
      page_index: 0,
      item_index: 0,
      destination_kind: 'azure_structured_item',
      structured_item_index: 0,
      name_line_index: 1,
      reference_line_index: 2,
      purchased_quantity_line_indexes: [ 3 ],
      printed_total_line_index: 4,
      owned_line_indexes: [ 1, 2, 3, 4 ],
      block_provider_span_start: 16,
      block_provider_span_end: 55,
      reference_line_provider_span_start: 23,
      reference_line_provider_span_end: 38,
      provider_model_id: 'prebuilt-receipt',
      provider_api_version: '2024-11-30',
      string_index_type: 'textElements',
      validation_contract_version: 'azure_item_layout_v1',
      validation_state: 'ambiguous',
      rejection_reasons: [ 'ambiguous_tax_inclusion' ],
      reference_price: {
        amount: '240',
        evidence: evidence(2, 29, 32)
      },
      reference_quantity: {
        amount: '100',
        unit_code: 'gram',
        unit_status: 'known',
        origin: 'explicit',
        evidence: evidence(2, 34, 38)
      },
      purchased_quantity: {
        amount: '250',
        unit_code: 'gram',
        unit_status: 'known',
        evidence: evidence(3, 43, 47)
      },
      reference_price_tax_inclusion: 'unknown',
      printed_line_total: {
        amount: '600',
        evidence: evidence(4, 49, 55)
      }
    }
  end

  def summary_gross_evidence(
    string_index_type: 'textElements',
    summary_amount: 600,
    summary_evidence: evidence(6, 73, 82),
    rate: '0.1',
    net_amount: 546,
    tax_amount: 54,
    gross_amount: 600,
    gross_evidence: evidence(5, 57, 68)
  )
    summary_evidence = summary_evidence.merge(string_index_type: string_index_type)
    gross_evidence = gross_evidence.merge(string_index_type: string_index_type)
    Ocr::ResponseParser::ReferencePricingSingleItemGrossSummaryEvidenceExtractor::Result.new(
      string_index_type: string_index_type,
      summary_total: summary_evidence.merge(amount: summary_amount),
      gross_tax_target: gross_evidence.merge(
        rate: rate,
        net_amount: net_amount,
        tax_amount: tax_amount,
        gross_amount: gross_amount
      )
    )
  end

  def candidate_with_line_indexes(
    name: 1,
    reference: 2,
    reference_quantity_line: reference,
    quantity: 3,
    total: 4,
    purchased_lines: [ quantity ]
  )
    value = candidate.deep_dup
    value[:candidate_id] =
      "azure_item_layout_p0_name_l#{name}_ref_l#{reference}_qty_l#{quantity}_total_l#{total}_reference_pricing"
    reference_start = reference * 10
    reference_quantity_start = reference_quantity_line * 10
    value[:reference_price][:evidence] = evidence(reference, reference_start + 1, reference_start + 4)
    value[:reference_quantity][:evidence] = evidence(
      reference_quantity_line,
      reference_quantity_start + (reference_quantity_line == reference ? 5 : 1),
      reference_quantity_start + (reference_quantity_line == reference ? 9 : 5)
    )
    value[:purchased_quantity][:evidence] = evidence(quantity, (quantity * 10) + 1, (quantity * 10) + 5)
    value[:printed_line_total][:evidence] = evidence(total, (total * 10) + 1, (total * 10) + 9)
    block_start = name * 10
    block_end = (total * 10) + 9
    value.merge!(
      item_identity: "azure_structured_item_i0_s#{block_start - 1}_e#{block_end + 1}",
      name_line_index: name,
      reference_line_index: reference,
      purchased_quantity_line_indexes: purchased_lines,
      printed_total_line_index: total,
      owned_line_indexes: (name..total).to_a,
      block_provider_span_start: block_start,
      block_provider_span_end: block_end,
      reference_line_provider_span_start: reference_start,
      reference_line_provider_span_end: reference_start + 9
    )
    value
  end

  def candidate_with_index_type(index_type)
    value = candidate.deep_dup
    value[:string_index_type] = index_type
    %i[reference_price reference_quantity purchased_quantity printed_line_total].each do |component|
      value[component][:evidence][:string_index_type] = index_type
    end
    value
  end

  def analyze_result
    line_contents = [
      '発行情報',
      '匿名商品',
      '240円/100g',
      '計量 250g',
      '明細計 600円',
      '10%対象計 ¥600',
      '(内税額 ¥54)',
      '合計 ¥600'
    ]
    content = line_contents.join("\n")
    offset = 0
    lines = line_contents.map do |line_content|
      length = line_content.scan(/\X/u).size
      line = {
        'content' => line_content,
        'spans' => [ { 'offset' => offset, 'length' => length } ]
      }
      offset += length + 1
      line
    end
    {
      'modelId' => 'prebuilt-receipt',
      'apiVersion' => '2024-11-30',
      'stringIndexType' => 'textElements',
      'content' => content,
      'pages' => [
        {
          'pageNumber' => 1,
          'unit' => 'pixel',
          'width' => 800,
          'height' => 1_200,
          'lines' => lines
        }
      ]
    }
  end

  def result_line_span(result, line_index)
    span = result.dig('pages', 0, 'lines', line_index, 'spans', 0)
    {
      span_start: span.fetch('offset'),
      span_end: span.fetch('offset') + span.fetch('length')
    }
  end

  def candidate_for_result(result)
    value = candidate.deep_dup
    {
      purchased_quantity: 3,
      printed_line_total: 4
    }.each do |component, line_index|
      span = result_line_span(result, line_index)
      value[component][:evidence] = evidence(line_index, span.fetch(:span_start), span.fetch(:span_end))
    end
    reference_span = result_line_span(result, 2)
    value[:reference_price][:evidence] = evidence(
      2,
      reference_span.fetch(:span_start),
      reference_span.fetch(:span_start) + 4
    )
    value[:reference_quantity][:evidence] = evidence(
      2,
      reference_span.fetch(:span_start) + 5,
      reference_span.fetch(:span_end)
    )
    block_start = result_line_span(result, 1).fetch(:span_start)
    block_end = result_line_span(result, 4).fetch(:span_end)
    parent_start = block_start - 1
    parent_end = block_end + 1
    value[:item_identity] = "azure_structured_item_i0_s#{parent_start}_e#{parent_end}"
    value[:block_provider_span_start] = block_start
    value[:block_provider_span_end] = block_end
    reference_line_span = result_line_span(result, 2)
    value[:reference_line_provider_span_start] = reference_line_span.fetch(:span_start)
    value[:reference_line_provider_span_end] = reference_line_span.fetch(:span_end)
    value
  end

  def call_policy(
    candidate_value: candidate,
    item_identities: [ candidate_value[:item_identity] ],
    block_candidate_ids: [ candidate_value[:candidate_id] ],
    destination_identities: [ candidate_value[:item_identity] ],
    summary_gross_evidence: summary_gross_evidence(),
    adjustment_count: 0,
    discount_count: 0,
    competing_tax_basis_count: 0,
    item_line_total_limit: ITEM_LINE_TOTAL_LIMIT
  )
    described_class.call(
      candidate: candidate_value,
      item_identities: item_identities,
      block_candidate_ids: block_candidate_ids,
      destination_identities: destination_identities,
      summary_gross_evidence: summary_gross_evidence,
      adjustment_count: adjustment_count,
      discount_count: discount_count,
      competing_tax_basis_count: competing_tax_basis_count,
      item_line_total_limit: item_line_total_limit
    )
  end

  it '単一明細のstrict summaryと正税率gross groupがformulaに完全一致するとgross eligibleにする' do
    source = Marshal.load(Marshal.dump(candidate))
    result = call_policy(candidate_value: source)

    aggregate_failures do
      expect(result).to be_eligible
      expect(result.reason).to eq('eligible')
      expect(result.reference_price_tax_inclusion).to eq('gross')
      expect(result.evidence_kind).to eq('single_item_receipt_gross_summary')
      expect(result.candidate_id).to eq(candidate[:candidate_id])
      expect(result.item_identity).to eq(candidate[:item_identity])
      expect(result.contract_version).to eq('reference_pricing_single_item_gross_summary_policy_v1')
      expect(result.to_h.to_json).not_to match(/raw_text|polygon|例示/)
      expect(source).to eq(candidate)
      expect(result).to be_frozen
      expect(result.reason).to be_frozen
      expect(result.candidate_id).to be_frozen
      expect(result.item_identity).to be_frozen
      expect(result.contract_version).to be_frozen
    end
  end

  it '実EvidenceExtractorのtyped Resultをそのまま受けてgross eligibleにする' do
    result = analyze_result
    source_candidate = candidate_for_result(result)
    summary_gross_evidence =
      Ocr::ResponseParser::ReferencePricingSingleItemGrossSummaryEvidenceExtractor.call(
        analyze_result: result,
        profile: ReceiptAnalysisProfiles.default,
        receipt_total: 600,
        receipt_tax: 54,
        existing_tax_details: [
          { rate: nil, net_amount: nil, amount: 54 },
          { rate: nil, net_amount: nil, amount: 54 }
        ],
        excluded_span_ranges: [
          {
            span_start: result_line_span(result, 1).fetch(:span_start),
            span_end: result_line_span(result, 4).fetch(:span_end)
          }
        ]
      )

    aggregate_failures do
      expect(summary_gross_evidence).to be_a(
        Ocr::ResponseParser::ReferencePricingSingleItemGrossSummaryEvidenceExtractor::Result
      )
      expect(
        call_policy(
          candidate_value: source_candidate,
          summary_gross_evidence: summary_gross_evidence
        )
      ).to be_eligible
    end
  end

  it 'item・block・destination identityが0件または2件ならfail-closedにする' do
    %i[item_identities block_candidate_ids destination_identities].each do |identity_name|
      [ [], %w[first second] ].each do |identities|
        expect(call_policy(**{ identity_name => identities }).reason).to eq('receipt_scope_invalid')
      end
    end

    expect(call_policy(item_identities: 'one').reason).to eq('receipt_scope_invalid')
  end

  it 'item・block・destination identityのsoleがcandidateと一致しなければfail-closedにする' do
    aggregate_failures do
      expect(call_policy(item_identities: [ 'mismatched' ]).reason).to eq('receipt_scope_invalid')
      expect(call_policy(block_candidate_ids: [ 'mismatched' ]).reason).to eq('receipt_scope_invalid')
      expect(call_policy(destination_identities: [ 'mismatched' ]).reason).to eq('receipt_scope_invalid')
    end
  end

  it 'typed extractor Result以外または不正なstructural evidenceを拒否する' do
    invalid_summary = summary_gross_evidence(
      summary_evidence: evidence(6, 73, 82).merge(raw_text: '合計 600円')
    )
    invalid_gross = summary_gross_evidence(
      gross_evidence: evidence(5, 57, 68).merge(description: '10%対象')
    )

    aggregate_failures do
      expect(call_policy(summary_gross_evidence: nil).reason).to eq('evidence_invalid')
      expect(call_policy(summary_gross_evidence: {}).reason).to eq('evidence_invalid')
      expect(call_policy(summary_gross_evidence: invalid_summary).reason).to eq('summary_total_invalid')
      expect(call_policy(summary_gross_evidence: invalid_gross).reason).to eq('tax_group_invalid')
    end
  end

  it '候補stateとrejection reasonがambiguous_tax_inclusionだけでなければ拒否する' do
    mutations = [
      candidate.merge(validation_state: 'valid'),
      candidate.merge(rejection_reasons: []),
      candidate.merge(rejection_reasons: [ 'ambiguous_tax_inclusion', 'discount_conflict' ]),
      candidate.merge(rejection_reasons: [ 'discount_conflict' ])
    ]

    mutations.each do |mutation|
      expect(call_policy(candidate_value: mutation).reason).to eq('candidate_invalid')
    end
  end

  it 'source・provider contract・identityがstrict layout contractと異なる候補を拒否する' do
    mutations = [
      candidate.merge(source_kind: 'azure_line_group'),
      candidate.merge(provider_model_id: 'unknown'),
      candidate.merge(provider_api_version: 'unknown'),
      candidate.merge(string_index_type: 'unicodeCodePoint'),
      candidate.merge(validation_contract_version: 'azure_item_layout_v2'),
      candidate.merge(candidate_id: 'azure_structured_item_i0_reference_pricing'),
      candidate.merge(
        candidate_id: 'azure_item_layout_p0_name_l01_ref_l2_qty_l3_total_l4_reference_pricing'
      ),
      candidate.merge(item_identity: 'azure_line_group_item_p0_l1_l2')
    ]

    mutations.each do |mutation|
      expect(call_policy(candidate_value: mutation).reason).to eq('candidate_invalid')
    end
  end

  it 'provider-backed structured destinationだけを許可する' do
    layout_identity = 'azure_item_layout_item_p0_name_l1_s16_e22_ref_l2_qty_l3_total_l4'
    layout_candidate = candidate.merge(
      item_identity: layout_identity,
      destination_kind: 'azure_layout_item',
      structured_item_index: nil
    )

    aggregate_failures do
      expect(call_policy).to be_eligible
      expect(call_policy(candidate_value: layout_candidate)).not_to be_eligible
      expect(call_policy(candidate_value: layout_candidate.merge(structured_item_index: 0))).not_to be_eligible
      expect(call_policy(candidate_value: layout_candidate.merge(item_index: 1))).not_to be_eligible
      expect(call_policy(candidate_value: layout_candidate.merge(structured_item_index: 1))).not_to be_eligible
    end
  end

  it 'utf16CodeUnitのexact component evidenceを許可する' do
    expect(
      call_policy(
        candidate_value: candidate_with_index_type('utf16CodeUnit'),
        summary_gross_evidence: summary_gross_evidence(string_index_type: 'utf16CodeUnit')
      )
    ).to be_eligible
  end

  it 'candidate IDのline index上限を許可し上限超過を拒否する' do
    maximum = candidate_with_line_indexes(name: 146, reference: 147, quantity: 148, total: 149)
    oversized = candidate_with_line_indexes(name: 147, reference: 148, quantity: 149, total: 150)

    aggregate_failures do
      expect(call_policy(candidate_value: maximum)).to be_eligible
      expect(call_policy(candidate_value: oversized).reason).to eq('candidate_invalid')
    end
  end

  it 'producerが生成しないsame-line・逆順・gap過大のline構造を拒否する' do
    invalid_candidates = [
      candidate_with_line_indexes(name: 1, reference: 1, quantity: 1, total: 1),
      candidate_with_line_indexes(name: 1, reference: 3, quantity: 2, total: 5),
      candidate_with_line_indexes(name: 1, reference: 2, quantity: 4, total: 6)
    ]

    invalid_candidates.each do |invalid_candidate|
      expect(call_policy(candidate_value: invalid_candidate).reason).to eq('candidate_invalid')
    end
  end

  it 'producerのordinary・補助行・quantity先行・column構造を許可する' do
    producer_lines = [
      { name: 1, reference: 2, quantity: 3, total: 4 },
      { name: 1, reference: 2, quantity: 4, total: 5 },
      { name: 1, reference: 2, quantity: 4, total: 5, purchased_lines: [ 3, 4 ] },
      { name: 1, reference: 3, quantity: 2, total: 4 },
      { name: 1, reference: 3, reference_quantity_line: 2, quantity: 4, total: 5 }
    ]

    producer_lines.each do |line_indexes|
      external_evidence = if line_indexes.fetch(:total) == 5
        summary_gross_evidence(
          gross_evidence: evidence(6, 61, 68),
          summary_evidence: evidence(7, 73, 82)
        )
      else
        summary_gross_evidence()
      end
      result = call_policy(
        candidate_value: candidate_with_line_indexes(**line_indexes),
        summary_gross_evidence: external_evidence
      )
      expect(result).to be_eligible, "#{line_indexes.inspect}: #{result.reason}"
    end
  end

  it 'column producerのheader基準数量とprice line基準価格を許可する' do
    column_candidate = candidate_with_line_indexes(
      name: 1,
      reference: 3,
      reference_quantity_line: 2,
      quantity: 4,
      total: 5
    )
    external_evidence = summary_gross_evidence(
      gross_evidence: evidence(6, 61, 68),
      summary_evidence: evidence(7, 73, 82)
    )

    aggregate_failures do
      expect(
        call_policy(candidate_value: column_candidate, summary_gross_evidence: external_evidence)
      ).to be_eligible
      expect(
        call_policy(
          candidate_value: column_candidate.deep_merge(
            reference_quantity: { evidence: evidence(3, 35, 39) }
          ),
          summary_gross_evidence: external_evidence
        ).reason
      ).to eq('candidate_invalid')
    end
  end

  it 'component evidence lineとcandidate IDのlineが一致しなければ拒否する' do
    mismatched_reference = candidate.deep_merge(
      reference_price: { evidence: evidence(5, 29, 32) }
    )

    expect(call_policy(candidate_value: mismatched_reference).reason).to eq('candidate_invalid')
  end

  it 'descriptor metadataのpage・destination・item・line・owned block不一致を拒否する' do
    mutations = [
      candidate.merge(page_index: 1),
      candidate.merge(item_index: 1),
      candidate.merge(destination_kind: 'azure_layout_item'),
      candidate.merge(structured_item_index: nil),
      candidate.merge(structured_item_index: 1),
      candidate.merge(name_line_index: 0),
      candidate.merge(reference_line_index: 3),
      candidate.merge(purchased_quantity_line_indexes: [ 2 ]),
      candidate.merge(printed_total_line_index: 3),
      candidate.merge(owned_line_indexes: [ 1, 2, 4 ]),
      candidate.merge(owned_line_indexes: [ 1, 2, 3, 4, 5 ]),
      candidate.merge(block_provider_span_start: 30),
      candidate.merge(block_provider_span_end: 54),
      candidate.merge(block_provider_span_start: 55, block_provider_span_end: 16),
      candidate.except(:reference_line_provider_span_start),
      candidate.except(:reference_line_provider_span_end),
      candidate.merge(reference_line_provider_span_start: 38, reference_line_provider_span_end: 23),
      candidate.merge(reference_line_provider_span_start: 15),
      candidate.merge(reference_line_provider_span_end: described_class::MAX_PROVIDER_SPAN + 1),
      candidate.merge(reference_line_provider_span_start: 30),
      candidate.merge(reference_line_provider_span_end: 35)
    ]

    mutations.each do |mutation|
      expect(call_policy(candidate_value: mutation).reason).to eq('candidate_invalid')
    end
  end

  it 'structured parent spanはfull block包含またはexact-single形だけを許可する' do
    exact_single = candidate.merge(item_identity: 'azure_structured_item_i0_s16_e38')

    aggregate_failures do
      expect(call_policy).to be_eligible
      expect(call_policy(candidate_value: exact_single)).to be_eligible
      expect(
        call_policy(candidate_value: candidate.merge(item_identity: 'azure_structured_item_i0_s17_e60')).reason
      ).to eq('candidate_invalid')
      expect(
        call_policy(candidate_value: candidate.merge(item_identity: 'azure_structured_item_i0_s10_e54')).reason
      ).to eq('candidate_invalid')
      expect(
        call_policy(candidate_value: candidate.merge(item_identity: 'azure_structured_item_i0_s60_e10')).reason
      ).to eq('candidate_invalid')
      expect(
        call_policy(candidate_value: candidate.merge(item_identity: 'azure_structured_item_i0_s15_e40')).reason
      ).to eq('candidate_invalid')
      expect(
        call_policy(candidate_value: candidate.merge(item_identity: 'azure_structured_item_i0_s16_e44')).reason
      ).to eq('candidate_invalid')
      (39..42).each do |gap_end|
        expect(
          call_policy(
            candidate_value: candidate.merge(item_identity: "azure_structured_item_i0_s16_e#{gap_end}")
          ).reason
        ).to eq('candidate_invalid')
      end
    end
  end

  it 'structured identityのitem indexとspan境界を検証する' do
    valid_maximum = 'azure_structured_item_i99_s10_e56'
    invalid_identities = [
      'azure_structured_item_i100_s57_e77',
      'azure_structured_item_i0_s77_e57',
      'azure_structured_item_i0_s57_e57',
      "azure_structured_item_i0_s0_e#{described_class::MAX_PROVIDER_SPAN + 1}"
    ]

    aggregate_failures do
      expect(
        call_policy(
          candidate_value: candidate.merge(
            item_identity: valid_maximum,
            item_index: 99,
            structured_item_index: 99
          )
        )
      ).to be_eligible
      invalid_identities.each do |identity|
        expect(call_policy(candidate_value: candidate.merge(item_identity: identity)).reason).to eq('candidate_invalid')
      end
    end
  end

  it 'canonical structured identityを許可し160/161 bytesのleading-zero aliasを拒否する' do
    prefix = 'azure_structured_item_i'
    suffix = '_s57_e77'
    identity_160 = prefix + ('0' * (160 - prefix.bytesize - suffix.bytesize)) + suffix
    identity_161 = prefix + ('0' * (161 - prefix.bytesize - suffix.bytesize)) + suffix
    maximum_canonical = candidate[:item_identity]
    maximum_candidate = candidate

    aggregate_failures do
      expect(maximum_canonical.bytesize).to be <= described_class::MAX_ID_BYTES
      expect(call_policy(candidate_value: maximum_candidate)).to be_eligible
      expect(identity_160.bytesize).to eq(160)
      expect(
        call_policy(candidate_value: candidate.merge(item_identity: identity_160)).reason
      ).to eq('candidate_invalid')
      expect(identity_161.bytesize).to eq(161)
      expect(
        call_policy(candidate_value: candidate.merge(item_identity: identity_161)).reason
      ).to eq('candidate_invalid')
    end
  end

  it 'exact source componentの欠損・不正decimal・unknown unit・dimension mismatchを拒否する' do
    mutations = [
      candidate.except(:reference_price),
      candidate.deep_merge(reference_price: { amount: '240.0' }),
      candidate.deep_merge(reference_quantity: { amount: '0' }),
      candidate.deep_merge(purchased_quantity: { amount: '250.0000' }),
      candidate.deep_merge(reference_price: { amount: '1000000000000' }),
      candidate.deep_merge(reference_quantity: { amount: '10000' }),
      candidate.deep_merge(reference_quantity: { unit_code: 'unknown' }),
      candidate.deep_merge(purchased_quantity: { unit_status: 'unknown' }),
      candidate.deep_merge(purchased_quantity: { unit_code: 'liter' }),
      candidate.deep_merge(printed_line_total: { amount: '-600' })
    ]

    mutations.each do |mutation|
      expect(call_policy(candidate_value: mutation).reason).to eq('candidate_invalid')
    end
  end

  it 'component evidenceの欠損・範囲外・raw field混入を拒否する' do
    mutations = [
      candidate.deep_merge(reference_price: { raw_text: '240円' }),
      candidate.deep_merge(reference_price: { evidence: nil }),
      candidate.deep_merge(reference_quantity: { evidence: { provider_span_end: 34 } }),
      candidate.deep_merge(purchased_quantity: { evidence: { line_index: 150 } }),
      candidate.deep_merge(printed_line_total: { evidence: { raw_text: '600円' } })
    ]

    mutations.each do |mutation|
      expect(call_policy(candidate_value: mutation).reason).to eq('candidate_invalid')
    end
  end

  it 'component spanの同一line重複・逆順・block外配置を拒否する' do
    mutations = [
      candidate.deep_merge(reference_quantity: { evidence: evidence(2, 29, 32) }),
      candidate.deep_merge(reference_quantity: { evidence: evidence(2, 31, 35) }),
      candidate.deep_merge(reference_quantity: { evidence: evidence(2, 20, 25) }),
      candidate.deep_merge(purchased_quantity: { evidence: evidence(3, 31, 35) }),
      candidate.deep_merge(printed_line_total: { evidence: evidence(4, 44, 50) }),
      candidate.deep_merge(reference_price: { evidence: evidence(2, 10, 14) }),
      candidate.deep_merge(purchased_quantity: { evidence: evidence(3, 56, 59) })
    ]

    mutations.each do |mutation|
      expect(call_policy(candidate_value: mutation).reason).to eq('candidate_invalid')
    end
  end

  it 'summary・gross targetのprovider/path/index/span contract不一致を拒否する' do
    invalid_values = [
      summary_gross_evidence(summary_evidence: evidence(6, 73, 82).merge(source_provider: 'azure_structured')),
      summary_gross_evidence(summary_evidence: evidence(6, 73, 82).merge(source_field_path: 'pages[0].lines[5]')),
      summary_gross_evidence(summary_evidence: evidence(6, 73, 82).merge(page_index: 1)),
      summary_gross_evidence(summary_evidence: evidence(150, 73, 82)),
      summary_gross_evidence(summary_evidence: evidence(6, 82, 73)),
      summary_gross_evidence(gross_evidence: evidence(5, -1, 68)),
      summary_gross_evidence(string_index_type: 'utf16CodeUnit')
    ]

    invalid_values.each do |invalid_value|
      expect(call_policy(summary_gross_evidence: invalid_value)).not_to be_eligible
    end
  end

  it 'summary・gross target相互またはcandidate full blockとのline/span overlapを拒否する' do
    overlapping_external = summary_gross_evidence(
      gross_evidence: evidence(6, 74, 80)
    )
    overlapping_component = summary_gross_evidence(
      summary_evidence: evidence(4, 50, 54)
    )
    overlapping_product_name = summary_gross_evidence(
      summary_evidence: evidence(1, 17, 20)
    )
    overlapping_owned_gap = summary_gross_evidence(
      gross_evidence: evidence(2, 40, 42)
    )
    contradictory_line_and_span = summary_gross_evidence(
      summary_evidence: evidence(0, 73, 82)
    )
    parent_overlaps_external = candidate.merge(item_identity: 'azure_structured_item_i0_s10_e90')

    aggregate_failures do
      expect(call_policy(summary_gross_evidence: overlapping_external).reason).to eq('evidence_invalid')
      expect(call_policy(summary_gross_evidence: overlapping_component).reason).to eq('evidence_invalid')
      expect(call_policy(summary_gross_evidence: overlapping_product_name).reason).to eq('evidence_invalid')
      expect(call_policy(summary_gross_evidence: overlapping_owned_gap).reason).to eq('evidence_invalid')
      expect(call_policy(summary_gross_evidence: contradictory_line_and_span).reason).to eq('evidence_invalid')
      expect(call_policy(candidate_value: parent_overlaps_external).reason).to eq('evidence_invalid')
    end
  end

  it '0以下のrate、Float rate、非正規rate、net/tax/gross不整合を拒否する' do
    evidence_values = [
      summary_gross_evidence(rate: '0'),
      summary_gross_evidence(rate: '-0.1'),
      summary_gross_evidence(rate: 0.1),
      summary_gross_evidence(rate: '0.10'),
      summary_gross_evidence(net_amount: 545),
      summary_gross_evidence(net_amount: 500, tax_amount: 100),
      summary_gross_evidence(tax_amount: -1),
      summary_gross_evidence(gross_amount: 601)
    ]

    evidence_values.each do |evidence_value|
      expect(call_policy(summary_gross_evidence: evidence_value).reason).to eq('tax_group_invalid')
    end
  end

  it 'extractor契約どおりtax amountが0円のgroupを拒否する' do
    evidence_value = summary_gross_evidence(net_amount: 600, tax_amount: 0)

    expect(call_policy(summary_gross_evidence: evidence_value).reason).to eq('tax_group_invalid')
  end

  it 'adjustment・discount・competing tax basisが1件でもあれば拒否する' do
    %i[adjustment_count discount_count competing_tax_basis_count].each do |count_name|
      [ 1, 2, -1, nil ].each do |count|
        expect(call_policy(**{ count_name => count }).reason).to eq('conflict_present')
      end
    end
  end

  it '0円のformula・印字明細・summary・tax grossをgross evidenceにしない' do
    zero_formula = candidate.deep_merge(reference_price: { amount: '0' })
    zero_printed = candidate.deep_merge(printed_line_total: { amount: '0' })

    aggregate_failures do
      expect(call_policy(candidate_value: zero_formula).reason).to eq('projection_invalid')
      expect(call_policy(candidate_value: zero_printed).reason).to eq('candidate_invalid')
      expect(
        call_policy(summary_gross_evidence: summary_gross_evidence(summary_amount: 0)).reason
      ).to eq('summary_total_invalid')
      expect(
        call_policy(
          summary_gross_evidence: summary_gross_evidence(net_amount: 0, tax_amount: 0, gross_amount: 0)
        ).reason
      ).to eq('tax_group_invalid')
    end
  end

  it 'item line total limitを明示しlimit境界を超える値を拒否する' do
    aggregate_failures do
      expect(call_policy(item_line_total_limit: 600)).to be_eligible
      expect(call_policy(item_line_total_limit: 599).reason).to eq('candidate_invalid')
      expect(call_policy(item_line_total_limit: 0).reason).to eq('amount_limit_invalid')
      expect(call_policy(item_line_total_limit: nil).reason).to eq('amount_limit_invalid')
      expect(
        call_policy(item_line_total_limit: described_class::MAX_PRICE_AMOUNT.to_i + 1).reason
      ).to eq('amount_limit_invalid')
    end
  end

  it 'projection・印字明細合計・tax gross・receipt Totalの1円差をすべて拒否する' do
    projection_mismatch = candidate.deep_merge(reference_price: { amount: '240.4' })
    printed_mismatch = candidate.deep_merge(printed_line_total: { amount: '601' })

    aggregate_failures do
      expect(call_policy(candidate_value: projection_mismatch).reason).to eq('amount_mismatch')
      expect(call_policy(candidate_value: printed_mismatch).reason).to eq('amount_mismatch')
      expect(
        call_policy(summary_gross_evidence: summary_gross_evidence(summary_amount: 601)).reason
      ).to eq('amount_mismatch')
      expect(
        call_policy(
          summary_gross_evidence: summary_gross_evidence(
            net_amount: 547,
            tax_amount: 54,
            gross_amount: 601
          )
        ).reason
      ).to eq('amount_mismatch')
    end
  end

  it 'DB・OCR・AI・current timeに依存せずauthorityを変更しない' do
    queries = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:name].in?(%w[SCHEMA CACHE])
      next if payload[:sql].match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)

      queries << payload[:sql]
    end
    allow(ReceiptOcrService).to receive(:call)
    allow(ReceiptAiEnrichmentService).to receive(:call)
    allow(Time).to receive(:current)
    allow(ReceiptItem).to receive(:create!).and_call_original

    expect {
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        expect(call_policy).to be_eligible
      end
    }.not_to change(ReceiptItem, :count)

    aggregate_failures do
      expect(queries).to be_empty
      expect(ReceiptOcrService).not_to have_received(:call)
      expect(ReceiptAiEnrichmentService).not_to have_received(:call)
      expect(Time).not_to have_received(:current)
      expect(ReceiptItem).not_to have_received(:create!)
    end
  end
end
