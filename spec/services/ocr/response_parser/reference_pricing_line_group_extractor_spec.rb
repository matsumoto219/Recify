require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ReferencePricingLineGroupExtractor do
  LINE_GROUP_EXTRACTOR_FIXTURE_PATH = Rails.root.join(
    'spec/fixtures/ocr/ocr_azure_measurement_line_group_anonymized.json'
  )

  def fixture_analyze_result
    JSON.parse(LINE_GROUP_EXTRACTOR_FIXTURE_PATH.read).fetch('analyzeResult')
  end

  def extract(analyze_result = fixture_analyze_result, profile: ReceiptAnalysisProfiles.fetch('JPN'))
    described_class.call(
      analyze_result: analyze_result,
      profile:,
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    )
  end

  def text_element_length(value)
    value.scan(/\X/).length
  end

  def text_element_offset(value, character_offset)
    value[0...character_offset].to_s.scan(/\X/).length
  end

  def synthetic_analyze_result(lines, string_index_type: 'textElements')
    content = lines.join("\n")
    cursor = 0
    words = []
    page_lines = lines.each_with_index.map do |line, line_index|
      line_length = text_element_length(line)
      y = 10 + (line_index * 22)

      line.to_enum(:scan, /\S+/).each_with_index do |word, word_index|
        match = Regexp.last_match
        word_offset = cursor + text_element_offset(line, match.begin(0))
        x = 20 + (word_index * 55)
        words << {
          'content' => word,
          'polygon' => [ x, y, x + 45, y, x + 45, y + 16, x, y + 16 ],
          'confidence' => 0.99,
          'span' => { 'offset' => word_offset, 'length' => text_element_length(word) }
        }
      end

      entry = {
        'content' => line,
        'polygon' => [ 20, y, 200, y, 200, y + 16, 20, y + 16 ],
        'spans' => [ { 'offset' => cursor, 'length' => line_length } ]
      }
      cursor += line_length + 1
      entry
    end

    {
      'apiVersion' => '2024-11-30',
      'modelId' => 'prebuilt-receipt',
      'stringIndexType' => string_index_type,
      'content' => content,
      'pages' => [
        {
          'pageNumber' => 1,
          'width' => 300,
          'height' => [ 100, lines.length * 30 ].max,
          'unit' => 'pixel',
          'words' => words,
          'lines' => page_lines
        }
      ],
      'documents' => [
        {
          'docType' => 'receipt.retailMeal',
          'fields' => {
            'Items' => { 'type' => 'array', 'valueArray' => [] }
          }
        }
      ]
    }
  end

  it 'extracts one valid typed candidate from the strict anonymous two-line block' do
    candidate = extract.sole

    aggregate_failures do
      expect(candidate).to include(
        candidate_id: 'azure_line_group_p0_l1_l2_reference_pricing',
        source_kind: 'azure_line_group',
        page_index: 0,
        reference_line_index: 1,
        purchased_quantity_line_index: 2,
        string_index_type: 'textElements',
        validation_state: 'valid',
        rejection_reasons: [],
        reference_price_tax_inclusion: 'gross',
        printed_line_total: nil
      )
      expect(candidate).not_to have_key(:item_index)
      expect(candidate[:reference_price]).to include(amount: '120')
      expect(candidate[:reference_quantity]).to include(
        amount: '1',
        unit_code: 'liter',
        unit_status: 'known',
        origin: 'explicit'
      )
      expect(candidate[:purchased_quantity]).to include(
        amount: '2.5',
        unit_code: 'liter',
        unit_status: 'known'
      )
      expect(candidate[:summary_total_corroboration]).to eq(
        exact_amount: { numerator: '300', denominator: '1' },
        projected_amount: 300,
        summary_total: '300',
        rounding_matches: %w[floor half_up ceil]
      )
    end
  end

  it 'accepts bounded at-sign notation without broadening the structured Items path' do
    [ '@', '＠' ].each do |at_sign|
      candidate = extract(
        synthetic_analyze_result([
          'SYNTH-AT-SIGN',
          "検証品A01 税込#{at_sign}120円/1 L",
          '計量 2.5 L'
        ])
      ).sole

      expect(candidate).to include(
        validation_state: 'valid',
        reference_price_tax_inclusion: 'gross'
      )
      expect(candidate[:reference_price]).to include(amount: '120')
      expect(candidate[:reference_quantity]).to include(amount: '1', unit_code: 'liter')
      expect(candidate[:purchased_quantity]).to include(amount: '2.5', unit_code: 'liter')
    end
  end

  it 'uses injected purchased-quantity vocabulary and identifier script rules' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_reference_pricing_line_group_purchased_quantity_line_pattern)
      .and_return(/\A[ \t]*MEASURE[ \t]+[0-9]+(?:\.[0-9]+)?[ \t]*[A-Za-z]+[ \t]*\z/)
    allow(profile).to receive(:ocr_reference_pricing_line_group_identifier_pattern)
      .and_return(/\AITEM-[A-Z0-9_-]*\z/)

    custom_extract = lambda do |purchased_line|
      extract(
        synthetic_analyze_result([
          'SYNTH-CUSTOM-PROFILE',
          'ITEM-A03 税込120円/1 L',
          purchased_line
        ]),
        profile:
      )
    end

    aggregate_failures do
      expect(custom_extract.call('MEASURE 2.5 L').sole).to include(
        validation_state: 'valid',
        reference_price_tax_inclusion: 'gross'
      )
      expect(custom_extract.call('計量 2.5 L')).to eq([])
    end
  end

  it 'uses injected package vocabulary' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_reference_pricing_line_group_package_or_uncertain_pattern)
      .and_return(/CUSTOM_PACKAGE/)

    result = extract(
      synthetic_analyze_result([
        'SYNTH-CUSTOM-PACKAGE',
        '検証品A01CUSTOM_PACKAGE 税込120円/1 L',
        '計量 2.5 L'
      ]),
      profile:
    )

    expect(result).to eq([])
  end

  it 'uses injected discount-conflict vocabulary' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_reference_pricing_line_group_discount_conflict_pattern)
      .and_return(/CUSTOM_DISCOUNT/)

    result = extract(
      synthetic_analyze_result([
        'SYNTH-CUSTOM-DISCOUNT',
        '検証品A01 税込120円/1 L',
        '計量 2.5 L',
        'CUSTOM_DISCOUNT'
      ]),
      profile:
    )

    expect(result).to eq([])
  end

  it 'uses injected summary and identifier-conflict vocabulary' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_reference_pricing_line_group_summary_context_pattern)
      .and_return(/CUSTOM_SUMMARY/)
    allow(profile).to receive(:ocr_reference_pricing_line_group_identifier_conflict_pattern)
      .and_return(/CUSTOM_CONFLICT/)

    results = [ 'CUSTOM_SUMMARY', 'CUSTOM_CONFLICT' ].map do |suffix|
      extract(
        synthetic_analyze_result([
          'SYNTH-CUSTOM-IDENTIFIER-CONFLICT',
          "検証品A01#{suffix} 税込120円/1 L",
          '計量 2.5 L'
        ]),
        profile:
      )
    end

    expect(results).to eq([ [], [] ])
  end

  it 'uses the injected strict receipt subtotal line' do
    profile = ReceiptAnalysisProfiles.fetch('JPN')
    allow(profile).to receive(:ocr_strict_receipt_subtotal_line_pattern)
      .and_return(/\ACUSTOM_SUBTOTAL 300円\z/)

    candidate = extract(
      synthetic_analyze_result([
        'SYNTH-CUSTOM-SUBTOTAL',
        '検証品A01 税込120円/1 L',
        '計量 2.5 L',
        'CUSTOM_SUBTOTAL 300円'
      ]),
      profile:
    ).sole

    expect(candidate).to include(validation_state: 'valid')
  end

  it 'keeps deterministic implicit per-unit notation as an explicit contract' do
    candidate = extract(
      synthetic_analyze_result([
        'SYNTH-IMPLICIT-PER-UNIT',
        '検証品A02 税込 120円/L',
        '計量 2.5 L'
      ])
    ).sole

    expect(candidate[:reference_quantity]).to include(
      amount: '1',
      unit_code: 'liter',
      origin: 'implicit_per_unit'
    )
  end

  it 'binds components to exact textElements spans and line paths without a fabricated item index' do
    candidate = extract.sole
    expectations = {
      reference_price: [ 'pages[0].lines[1]', 16, 19 ],
      reference_quantity: [ 'pages[0].lines[1]', 21, 24 ],
      purchased_quantity: [ 'pages[0].lines[2]', 28, 33 ]
    }

    expectations.each do |component, (path, span_start, span_end)|
      evidence = candidate.dig(component, :evidence)

      aggregate_failures component do
        expect(evidence).to include(
          source_provider: 'azure_line_group',
          source_field_path: path,
          provider_span_start: span_start,
          provider_span_end: span_end,
          string_index_type: 'textElements'
        )
        expect(evidence).not_to have_key(:item_index)
      end
    end

    expect(candidate[:tax_inclusion_evidence]).to include(
      source_provider: 'azure_line_group',
      source_field_path: 'pages[0].lines[1]',
      provider_span_start: 13,
      provider_span_end: 15,
      string_index_type: 'textElements'
    )
  end

  it 'keeps an item-local net label bound when the explicit rate appears before the reference expression' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-NET',
      '税抜10% 173円/250ml',
      '計量 1.500L',
      '合計 1,142円'
    ])

    candidate = extract(analyze_result).sole

    aggregate_failures do
      expect(candidate).to include(
        validation_state: 'valid',
        rejection_reasons: [],
        reference_price_tax_inclusion: 'net',
        printed_line_total: nil
      )
      expect(candidate[:tax_inclusion_evidence]).to include(
        source_provider: 'azure_line_group',
        source_field_path: 'pages[0].lines[1]'
      )
    end
  end

  it 'supports the existing utf16CodeUnit index contract without inventing another index model' do
    analyze_result = synthetic_analyze_result(
      [ 'SYNTH-UTF16', '税込 120円/1 L', '計量 2.5 L' ],
      string_index_type: 'utf16CodeUnit'
    )

    candidate = extract(analyze_result).sole

    expect(candidate).to include(
      validation_state: 'valid',
      string_index_type: 'utf16CodeUnit',
      printed_line_total: nil
    )
  end

  it 'fails closed outside the provider model and API version proven by the evidence corpus' do
    unknown_model = fixture_analyze_result.deep_dup
    unknown_model['modelId'] = 'unknown-model'
    unknown_version = fixture_analyze_result.deep_dup
    unknown_version['apiVersion'] = '2099-01-01'

    expect([ extract(unknown_model), extract(unknown_version) ]).to all(eq([]))
  end

  it 'preserves a fullwidth summary amount without treating it as an item total' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-FULLWIDTH-SUMMARY',
      '税込 120円/1 L',
      '計量 2.5 L',
      '合計 ３００円'
    ])
    summary_line = analyze_result.dig('pages', 0, 'lines', 3)
    amount_index = summary_line.fetch('content').index('３００')
    analyze_result.dig('documents', 0, 'fields')['Total'] = {
      'type' => 'currency',
      'content' => '３００',
      'spans' => [
        {
          'offset' => summary_line.dig('spans', 0, 'offset') +
            text_element_offset(summary_line.fetch('content'), amount_index),
          'length' => text_element_length('３００')
        }
      ],
      'valueCurrency' => { 'amount' => 300, 'currencyCode' => 'JPY' }
    }

    candidate = extract(analyze_result).sole

    aggregate_failures do
      expect(candidate[:printed_line_total]).to be_nil
      expect(candidate[:summary_total_corroboration]).to include(
        projected_amount: 300,
        summary_total: '300',
        rounding_matches: %w[floor half_up ceil]
      )
    end
  end

  it 'keeps only the bounded one-pixel word and line polygon tolerance' do
    analyze_result = fixture_analyze_result.deep_dup
    price_word = analyze_result.dig('pages', 0, 'words').find do |word|
      word.fetch('content').include?('120')
    end
    polygon = price_word.fetch('polygon')
    line_left = analyze_result.dig('pages', 0, 'lines', 1, 'polygon', 0)
    width = polygon[2] - polygon[0]
    polygon[0] = line_left - 1
    polygon[6] = line_left - 1
    polygon[2] = polygon[0] + width
    polygon[4] = polygon[0] + width

    expect(extract(analyze_result).sole).to include(validation_state: 'valid')
  end

  it 'fails closed for semantic and association negatives' do
    negative_results = {
      package: extract(synthetic_analyze_result([
        'SYNTH-PACKAGE', '税込 120円/1 L', '内容量 3個', '合計 360円'
      ])),
      count_unit_price: extract(synthetic_analyze_result([
        'SYNTH-COUNT', '税込 120円/1個', '計量 2個', '合計 240円'
      ])),
      discount: extract(synthetic_analyze_result([
        'SYNTH-DISCOUNT', '税込 値引 120円/1 L', '計量 2.5 L', '合計 300円'
      ])),
      intervening_line: extract(synthetic_analyze_result([
        'SYNTH-ADJACENT', '税込 120円/1 L', '別明細 90円', '計量 2.5 L', '合計 390円'
      ])),
      multiple_blocks: extract(synthetic_analyze_result([
        'SYNTH-MULTIPLE',
        '税込 120円/1 L', '計量 2.5 L',
        '税込 80円/1 L', '計量 1.5 L',
        '合計 420円'
      ]))
    }

    expect(negative_results).to all(satisfy { |_name, candidates| candidates == [] })
  end

  it 'fails closed for malformed layout evidence and unsupported index types' do
    malformed_polygon = fixture_analyze_result.deep_dup
    malformed_polygon.dig('pages', 0, 'lines', 1, 'polygon').pop

    malformed_span = fixture_analyze_result.deep_dup
    malformed_span.dig('pages', 0, 'lines', 1, 'spans', 0)['length'] += 1

    unsupported_index = fixture_analyze_result.deep_dup
    unsupported_index['stringIndexType'] = 'utf8Byte'

    unsupported_page_unit = fixture_analyze_result.deep_dup
    unsupported_page_unit.dig('pages', 0)['unit'] = 'inch'

    expect([
      extract(malformed_polygon),
      extract(malformed_span),
      extract(unsupported_index),
      extract(unsupported_page_unit)
    ]).to all(eq([]))
  end
end
