require 'rails_helper'
require 'timeout'

RSpec.describe Ocr::ResponseParser::ReferencePricingLineGroupExtractor, 'adversarial boundaries' do
  def profile
    ReceiptAnalysisProfiles.fetch('JPN')
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
      y = 10 + (line_index * 16)

      line.to_enum(:scan, /\S+/).each_with_index do |word, word_index|
        match = Regexp.last_match
        x = 20 + (word_index * 45)
        words << {
          'content' => word,
          'polygon' => [ x, y, x + 40, y, x + 40, y + 12, x, y + 12 ],
          'span' => {
            'offset' => cursor + text_element_offset(line, match.begin(0)),
            'length' => text_element_length(word)
          }
        }
      end

      page_line = {
        'content' => line,
        'polygon' => [ 20, y, 240, y, 240, y + 12, 20, y + 12 ],
        'spans' => [ { 'offset' => cursor, 'length' => line_length } ]
      }
      cursor += line_length + 1
      page_line
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
          'height' => [ 100, lines.length * 25 ].max,
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

  def add_document_total!(analyze_result, line_index:, field_span: nil, amount: nil)
    line = analyze_result.dig('pages', 0, 'lines', line_index)
    amount ||= line.fetch('content').scan(/\d[\d,，]*/).sole
    amount_offset = line.fetch('content').index(amount)
    span = line.fetch('spans').sole
    total_span = field_span || {
      'offset' => span.fetch('offset') + text_element_offset(line.fetch('content'), amount_offset),
      'length' => text_element_length(amount)
    }

    analyze_result.dig('documents', 0, 'fields')['Total'] = {
      'type' => 'currency',
      'content' => amount,
      'spans' => [ total_span ],
      'valueCurrency' => { 'amount' => amount.delete(',，').to_i, 'currencyCode' => 'JPY' }
    }
    analyze_result
  end

  def add_overlapping_item!(analyze_result, first_line_index:, last_line_index:)
    lines = analyze_result.dig('pages', 0, 'lines')
    first = lines.fetch(first_line_index)
    last = lines.fetch(last_line_index)
    offset = first.dig('spans', 0, 'offset')
    ending = last.dig('spans', 0, 'offset') + last.dig('spans', 0, 'length')
    analyze_result.dig('documents', 0, 'fields', 'Items', 'valueArray') << {
      'content' => analyze_result.fetch('content').scan(/\X/)[offset...ending].join,
      'spans' => [ { 'offset' => offset, 'length' => ending - offset } ],
      'valueObject' => {}
    }
    analyze_result
  end

  def extract(analyze_result, projection: ReceiptAmountService.method(:reference_item_extension_projection))
    described_class.call(analyze_result:, profile:, projection:)
  end

  def extract_lines(*lines, **options)
    extract(synthetic_analyze_result(lines, **options))
  end

  it 'distinguishes an explicit post-discount basis from a generic nearby discount' do
    post_discount = extract_lines(
      'SYNTH-BASIS-CONTROL',
      '値引後 税込 120円/1 L',
      '計量 2.5 L'
    )
    generic_discount = extract_lines(
      'SYNTH-GENERIC-DISCOUNT',
      '値引 -10円',
      '税込 120円/1 L',
      '計量 2.5 L'
    )

    aggregate_failures do
      expect(post_discount.sole).to include(
        validation_state: 'valid',
        reference_price_tax_inclusion: 'gross'
      )
      expect(generic_discount).to eq([])
    end
  end

  it 'rejects a strict block claimed by an overlapping Azure Item span' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-ITEM-OVERLAP',
      '税込 120円/1 L',
      '計量 2.5 L'
    ])
    add_overlapping_item!(analyze_result, first_line_index: 1, last_line_index: 2)

    expect(extract(analyze_result)).to eq([])
  end

  it 'fails closed for empty Azure Item parent evidence' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-EMPTY-ITEM',
      '税込 120円/1 L',
      '計量 2.5 L'
    ])
    analyze_result.dig('documents', 0, 'fields', 'Items')['valueArray'] = [
      {
        'content' => '',
        'spans' => [ { 'offset' => 0, 'length' => 0 } ],
        'valueObject' => {}
      }
    ]

    expect(extract(analyze_result)).to eq([])
  end

  it 'fails closed for an empty structured Azure Item field' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-EMPTY-FIELD',
      '税込 120円/1 L',
      '計量 2.5 L'
    ])
    header_line = analyze_result.dig('pages', 0, 'lines', 0)
    analyze_result.dig('documents', 0, 'fields', 'Items')['valueArray'] = [
      {
        'content' => header_line.fetch('content'),
        'spans' => header_line.fetch('spans').map(&:deep_dup),
        'valueObject' => {
          'Description' => {
            'content' => '',
            'spans' => [ { 'offset' => 0, 'length' => 0 } ],
            'valueString' => ''
          }
        }
      }
    ]

    expect(extract(analyze_result)).to eq([])
  end

  it 'fails closed when a span-only Azure Item child claims the strict block' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-SPAN-ONLY-FIELD',
      '税込 120円/1 L',
      '計量 2.5 L'
    ])
    header_line = analyze_result.dig('pages', 0, 'lines', 0)
    reference_line = analyze_result.dig('pages', 0, 'lines', 1)
    analyze_result.dig('documents', 0, 'fields', 'Items')['valueArray'] = [
      {
        'content' => header_line.fetch('content'),
        'spans' => header_line.fetch('spans').map(&:deep_dup),
        'valueObject' => {
          'Unknown' => {
            'spans' => reference_line.fetch('spans').map(&:deep_dup)
          }
        }
      }
    ]

    expect(extract(analyze_result)).to eq([])
  end

  it 'rejects an adjacent monetary item instead of assigning its following block by proximity' do
    preceding_lines = [
      '別明細 90円',
      '商品 500ml',
      '商品500ml',
      '水500mlボトル',
      'ABC500ml',
      '商品 500 g',
      '商品 3個',
      '商品3個入',
      '商品500ML',
      '商品2KG',
      '商品500ＭＬ',
      '3% OFF',
      '3%引',
      '３％引',
      'クーポン -3',
      'ｸｰﾎﾟﾝ -3',
      'ＣＯＵＰＯＮ -3',
      '３％ ＯＦＦ',
      '-3',
      '−3',
      '▲3',
      '△3',
      '-3.00',
      '+3',
      '＋3',
      '商品 -3',
      '商品 ▲3',
      '商品 +3',
      '調整 −3',
      'ADJ -3',
      '$90',
      '€90',
      '£90',
      '値引後 クーポン -3',
      '値引後 3% OFF',
      'discounted coupon -3',
      '値引後 値引 -3',
      '値引後 割引 -3',
      '割引済み 値引 -3',
      'discounted discount -3',
      '別明細 90',
      "別明細\t90",
      '商品A 1,200',
      'ITEM A 90.00',
      '90'
    ]

    expect(preceding_lines.map do |preceding|
      extract_lines(preceding, '税込 120円/1 L', '計量 2.5 L', '合計 300円')
    end).to all(eq([]))
  end

  it 'rejects adjacent return or cancellation labels even without an amount' do
    preceding_labels = [
      '返却',
      '払戻',
      '払い戻し',
      'RETURN',
      'NON-TAX商品A1',
      'NONTAX商品A1',
      '非課稅A1'
    ]
    following_labels = [ 'キャンセル', 'VOID', 'CANCEL' ]

    expect(preceding_labels.map do |label|
      extract_lines(label, '税込 120円/1 L', '計量 2.5 L')
    end).to all(eq([]))
    expect(following_labels.map do |label|
      extract_lines('SYNTH-ADJUSTMENT-LABEL', '税込 120円/1 L', '計量 2.5 L', label)
    end).to all(eq([]))
  end

  it 'rejects unconsumed qualifiers and negated tax labels in the strict reference line' do
    reference_lines = [
      '税込 120円/1 L 概算',
      '税込 120円/1 L approx',
      '税込 120円/1 L 3% OFF',
      '概算 税込 120円/1 L',
      '合計 300円 税込 120円/1 L',
      '通常100円 税込 120円/1 L',
      '非:税込 120円/1 L',
      '非（税込 120円/1 L）',
      'NOT 税込 120円/1 L',
      'ＮＯＴ：税込 120円/1 L'
    ]

    expect(reference_lines.map do |reference_line|
      extract_lines('SYNTH-STRICT-REFERENCE', reference_line, '計量 2.5 L')
    end).to all(eq([]))
  end

  it 'accepts only balanced optional parentheses in the strict reference expression' do
    accepted = [
      '検証品A03 税込 120円/1 L',
      '検証品A03 税込 (120円/1 L)',
      '検証品A03 税込(10%) 120円/1 L',
      '検証品A03 税込10% (120円/1 L)'
    ]
    rejected = [
      '検証品A03 税込( 120円/1 L',
      '検証品A03 税込 120円/1 L)',
      '検証品A03 税込10% ( 120円/1 L'
    ]

    expect(accepted.map do |reference_line|
      extract_lines('SYNTH-BALANCED', reference_line, '計量 2.5 L').size
    end).to all(eq(1))
    expect(rejected.map do |reference_line|
      extract_lines('SYNTH-UNBALANCED', reference_line, '計量 2.5 L')
    end).to all(eq([]))
  end

  it 'rejects tax, refund, and cancellation semantics hidden in an identifier-shaped prefix' do
    prefixes = [
      '非課税A1',
      '非課稅A1',
      '不課税A1',
      '無税A1',
      '免税A1',
      '課税対象外A1',
      '対象外A1',
      '税別A1',
      '外税A1',
      '税抜A1',
      'TAXFREE商品A1',
      'NON-TAX商品A1',
      'NONTAX商品A1',
      'EXEMPT商品A1',
      '返金A1',
      '返品A1',
      '返却A1',
      '払戻A1',
      '払い戻しA1',
      '取消A1',
      'キャンセルA1',
      'VOID商品A1',
      'REFUND商品A1',
      'RETURN商品A1',
      'CANCEL商品A1',
      '値引後商品A1',
      '割引後商品A1',
      '割引済み商品A1',
      'discounted商品A1'
    ]

    expect(prefixes.map do |prefix|
      extract_lines('SYNTH-PREFIX-CONFLICT', "#{prefix} 税込 120円/1 L", '計量 2.5 L')
    end).to all(eq([]))
    expect([ '税込A1', '内税A1' ].map do |prefix|
      extract_lines('SYNTH-PREFIX-CONFLICT', "#{prefix} 税抜 120円/1 L", '計量 2.5 L')
    end).to all(eq([]))
  end

  it 'rejects package mass or volume hidden before a Latin identifier suffix' do
    prefixes = [
      '商品500mlPET1',
      '商品500gPACK1',
      '商品2kgBAG1'
    ]

    expect(prefixes.map do |prefix|
      extract_lines('SYNTH-PACKAGE-PREFIX', "#{prefix} 税込 120円/1 L", '計量 2.5 L')
    end).to all(eq([]))
  end

  it 'allows only exact following receipt summary or subtotal lines with bare amounts' do
    following_lines = [
      '合計 300 円',
      '合計 300',
      'total 300',
      'total: 300',
      '小計 300',
      'subtotal 300'
    ]

    expect(following_lines.map do |following|
      extract_lines('SYNTH-SUMMARY', '税込 120円/1 L', '計量 2.5 L', following).size
    end).to all(eq(1))
  end

  it 'fails closed when the two components are not one unambiguous consecutive block' do
    cases = {
      intervening_line: [
        'SYNTH-INTERVENING', '税込 120円/1 L', '別明細 90円', '計量 2.5 L'
      ],
      line_wrap: [
        'SYNTH-WRAP', '税込 120円/1 L', '計量', '2.5 L'
      ],
      multiple_reference_expressions: [
        'SYNTH-MULTI-REFERENCE', '税込 120円/1 L 130円/1 L', '計量 2.5 L'
      ],
      multiple_purchased_on_line: [
        'SYNTH-MULTI-PURCHASED', '税込 120円/1 L', '計量 2.5 L 3.0 L'
      ],
      multiple_purchased_lines: [
        'SYNTH-MULTI-PURCHASED-LINES', '税込 120円/1 L', '計量 2.5 L', '計量 3.0 L'
      ]
    }

    expect(cases.transform_values { |lines| extract_lines(*lines) }).to all(
      satisfy { |_name, candidates| candidates == [] }
    )
  end

  it 'rejects a second clear reference expression outside the strict block' do
    out_of_block_expressions = [
      '$90/1 L',
      '€90/1 L',
      '£90/1 L',
      'USD 90/1 L',
      '@90/1 L'
    ]

    expect(out_of_block_expressions.map do |expression|
      extract_lines(
        'SYNTH-OUT-OF-BLOCK-REFERENCE',
        '税込 120円/1 L',
        '計量 2.5 L',
        '合計 300円',
        expression
      )
    end).to all(eq([]))
  end

  it 'rejects page ambiguity instead of associating lines across pages' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-PAGE-A', '税込 120円/1 L', '計量 2.5 L'
    ])
    second_page = synthetic_analyze_result([
      'SYNTH-PAGE-B', '税込 80円/1 L', '計量 1.5 L'
    ]).fetch('pages').sole
    second_page['pageNumber'] = 2
    analyze_result.fetch('pages') << second_page

    expect(extract(analyze_result)).to eq([])
  end

  it 'requires one item-local tax basis without conflicting gross and net markers' do
    cases = {
      unknown: [ 'SYNTH-TAX-UNKNOWN', '120円/1 L', '計量 2.5 L' ],
      conflict: [ 'SYNTH-TAX-CONFLICT', '税込 税抜 120円/1 L', '計量 2.5 L' ],
      suffixed_label: [ 'SYNTH-TAX-SUFFIX', '税込対象外 120円/1 L', '計量 2.5 L' ],
      prefixed_label: [ 'SYNTH-TAX-PREFIX', '非税込 120円/1 L', '計量 2.5 L' ],
      spaced_negated_label: [ 'SYNTH-TAX-NEGATED', '非 税込 120円/1 L', '計量 2.5 L' ]
    }

    expect(cases.transform_values { |lines| extract_lines(*lines) }).to all(
      satisfy { |_name, candidates| candidates == [] }
    )
  end

  it 'rejects unknown units and incompatible unit dimensions' do
    cases = {
      unknown_reference_unit: [ 'SYNTH-UNKNOWN-REF', '税込 120円/1 gal', '計量 2.5 gal' ],
      unknown_purchased_unit: [ 'SYNTH-UNKNOWN-PURCHASED', '税込 120円/1 L', '計量 2.5 gal' ],
      dimension_mismatch: [ 'SYNTH-DIMENSION', '税込 120円/1 L', '計量 2.5 kg' ]
    }

    expect(cases.transform_values { |lines| extract_lines(*lines) }).to all(
      satisfy { |_name, candidates| candidates == [] }
    )
  end

  it 'rejects approximate, ranged, tare, gross-weight, and nested package quantities' do
    cases = {
      approximate: [ 'SYNTH-APPROX', '税込 120円/1 L', '計量 約2.5 L' ],
      range: [ 'SYNTH-RANGE', '税込 120円/1 L', '計量 2〜3 L' ],
      approximate_suffix: [ 'SYNTH-APPROX-SUFFIX', '税込 120円/1 L 前後', '計量 2.5 L' ],
      estimate_suffix: [ 'SYNTH-ESTIMATE-SUFFIX', '税込 120円/1 L 目安', '計量 2.5 L' ],
      threshold_suffix: [ 'SYNTH-THRESHOLD-SUFFIX', '税込 120円/1 L 以上', '計量 2.5 L' ],
      dash_range: [ 'SYNTH-DASH-RANGE', '税込 120円/1 L - 2 L', '計量 2.5 L' ],
      tolerance: [ 'SYNTH-TOLERANCE', '税込 120円/1 L ±0.1 L', '計量 2.5 L' ],
      tare: [ 'SYNTH-TARE', '税込 120円/1 kg', '計量 2.5 kg 風袋' ],
      gross_weight: [ 'SYNTH-GROSS-WEIGHT', '税込 120円/1 kg', '計量 2.5 kg 総重量' ],
      nested_capacity: [ 'SYNTH-NESTED', '税込 120円/1 L 500ml×5', '計量 2.5 L' ]
    }

    expect(cases.transform_values { |lines| extract_lines(*lines) }).to all(
      satisfy { |_name, candidates| candidates == [] }
    )
  end

  it 'keeps a formula mismatch diagnostic-only without claiming corroboration' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-MISMATCH', '税込 120円/1 L', '計量 2.5 L', '合計 301円'
    ])
    add_document_total!(analyze_result, line_index: 3)

    candidate = extract(analyze_result).sole

    aggregate_failures do
      expect(candidate).to include(validation_state: 'valid', printed_line_total: nil)
      expect(candidate[:summary_total_corroboration]).to include(
        projected_amount: 300,
        summary_total: '301',
        rounding_matches: []
      )
    end
  end

  it 'does not manufacture corroboration from multiple or malformed summary Total evidence' do
    multiple = synthetic_analyze_result([
      'SYNTH-MULTI-TOTAL', '税込 120円/1 L', '計量 2.5 L', '合計 300円', '総合計 300円'
    ])
    add_document_total!(multiple, line_index: 4)

    malformed = synthetic_analyze_result([
      'SYNTH-MALFORMED-TOTAL', '税込 120円/1 L', '計量 2.5 L', '合計 300円'
    ])
    add_document_total!(malformed, line_index: 3)
    malformed.dig('documents', 0, 'fields', 'Total', 'spans') << { 'offset' => 0, 'length' => 1 }

    aggregate_failures do
      expect(extract(multiple).sole[:summary_total_corroboration]).to be_nil
      expect(extract(malformed).sole[:summary_total_corroboration]).to be_nil
    end
  end

  it 'does not use a document Total wholly inside the Measurement block as summary evidence' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-IN-BLOCK-TOTAL', '税込 120円/1 L', '計量 2.5 L'
    ])
    reference_line = analyze_result.dig('pages', 0, 'lines', 1)
    price_offset = reference_line.fetch('content').index('120')
    reference_span = reference_line.fetch('spans').sole
    add_document_total!(
      analyze_result,
      line_index: 1,
      field_span: {
        'offset' => reference_span.fetch('offset') + text_element_offset(reference_line.fetch('content'), price_offset),
        'length' => 3
      },
      amount: '120'
    )

    candidate = extract(analyze_result).sole

    aggregate_failures do
      expect(candidate).to include(validation_state: 'valid', printed_line_total: nil)
      expect(candidate[:summary_total_corroboration]).to be_nil
    end
  end

  it 'allows an in-block false Total field to yield to one explicit summary line outside the block' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-IN-BLOCK-FIELD', '税込 120円/1 L', '計量 2.5 L', '合計 300円'
    ])
    reference_line = analyze_result.dig('pages', 0, 'lines', 1)
    price_offset = reference_line.fetch('content').index('120')
    reference_span = reference_line.fetch('spans').sole
    add_document_total!(
      analyze_result,
      line_index: 1,
      field_span: {
        'offset' => reference_span.fetch('offset') + text_element_offset(reference_line.fetch('content'), price_offset),
        'length' => 3
      },
      amount: '120'
    )

    candidate = extract(analyze_result).sole

    expect(candidate[:summary_total_corroboration]).to include(
      projected_amount: 300,
      summary_total: '300',
      rounding_matches: %w[floor half_up ceil]
    )
  end

  it 'requires an out-of-block Total field span to belong to the selected summary line' do
    analyze_result = synthetic_analyze_result([
      '識別 999', 'SYNTH-HEADER', '税込 120円/1 L', '計量 2.5 L', '合計 300円'
    ])
    add_document_total!(analyze_result, line_index: 0)

    candidate = extract(analyze_result).sole

    expect(candidate[:summary_total_corroboration]).to be_nil
  end

  it 'requires the structured Total value to agree with its selected summary lexeme' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-VALUE-CHECK', '税込 120円/1 L', '計量 2.5 L', '合計 300円'
    ])
    add_document_total!(analyze_result, line_index: 3)
    analyze_result.dig('documents', 0, 'fields', 'Total', 'valueCurrency')['amount'] = 301

    candidate = extract(analyze_result).sole

    expect(candidate[:summary_total_corroboration]).to be_nil
  end

  it 'bounds structured Total types and magnitudes before decimal conversion' do
    oversized = synthetic_analyze_result([
      'SYNTH-TOTAL-BOUND', '税込 120円/1 L', '計量 2.5 L', '合計 300円'
    ])
    add_document_total!(oversized, line_index: 3)
    oversized.dig('documents', 0, 'fields', 'Total', 'valueCurrency')['amount'] = 10**10_000

    wrong_type = synthetic_analyze_result([
      'SYNTH-TOTAL-TYPE', '税込 120円/1 L', '計量 2.5 L', '合計 300円'
    ])
    add_document_total!(wrong_type, line_index: 3)
    wrong_type.dig('documents', 0, 'fields', 'Total', 'valueCurrency')['amount'] = '300'

    Timeout.timeout(2) do
      expect([ oversized, wrong_type ].map { |result| extract(result).sole[:summary_total_corroboration] }).to eq(
        [ nil, nil ]
      )
    end
  end

  it 'does not treat a tax-labelled ordinary item line as a receipt summary Total' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-NOT-SUMMARY', '税込 120円/1 L', '計量 2.5 L', '税込 200円'
    ])
    add_document_total!(analyze_result, line_index: 3)

    expect(extract(analyze_result)).to eq([])
  end

  it 'does not use a document Total span that partially crosses the strict block boundary' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-PARTIAL-TOTAL', '税込 120円/1 L', '計量 2.5 L', '合計 300円'
    ])
    purchased_line = analyze_result.dig('pages', 0, 'lines', 2)
    purchased_end = purchased_line.dig('spans', 0, 'offset') + purchased_line.dig('spans', 0, 'length')
    summary_line = analyze_result.dig('pages', 0, 'lines', 3)
    summary_amount_end = summary_line.dig('spans', 0, 'offset') + summary_line.fetch('content').index('300') + 3
    field_start = purchased_end - 1
    field_length = summary_amount_end - field_start
    analyze_result.dig('documents', 0, 'fields')['Total'] = {
      'type' => 'currency',
      'content' => analyze_result.fetch('content').scan(/\X/)[field_start, field_length].join,
      'spans' => [ { 'offset' => field_start, 'length' => field_length } ],
      'valueCurrency' => { 'amount' => 300, 'currencyCode' => 'JPY' }
    }

    candidate = extract(analyze_result).sole

    expect(candidate[:summary_total_corroboration]).to be_nil
  end

  it 'requires bounded nonoverlapping words that belong to page lines' do
    missing_words = synthetic_analyze_result([
      'SYNTH-NO-WORDS', '税込 120円/1 L', '計量 2.5 L'
    ])
    missing_words.dig('pages', 0)['words'] = []

    overlapping_words = synthetic_analyze_result([
      'SYNTH-WORD-OVERLAP', '税込 120円/1 L', '計量 2.5 L'
    ])
    overlapping_words.dig('pages', 0, 'words') <<
      overlapping_words.dig('pages', 0, 'words', 0).deep_dup

    missing_component_words = synthetic_analyze_result([
      'SYNTH-WORD-COVERAGE', '税込 120円/1 L', '計量 2.5 L'
    ])
    missing_component_words.dig('pages', 0)['words'].reject! do |word|
      word.fetch('content').include?('120') || word.fetch('content') == 'L'
    end

    outside_line_polygon = synthetic_analyze_result([
      'SYNTH-WORD-GEOMETRY', '税込 120円/1 L', '計量 2.5 L'
    ])
    price_word = outside_line_polygon.dig('pages', 0, 'words').find do |word|
      word.fetch('content').include?('120')
    end
    price_word['polygon'] = [ 20, 0, 60, 0, 60, 8, 20, 8 ]

    oversized_word_polygon = synthetic_analyze_result([
      'SYNTH-WORD-OVERHANG', '税込 120円/1 L', '計量 2.5 L'
    ])
    overhanging_price_word = oversized_word_polygon.dig('pages', 0, 'words').find do |word|
      word.fetch('content').include?('120')
    end
    overhanging_price_word['polygon'] = [ 0, 0, 140, 0, 140, 80, 0, 80 ]

    reversed_words = synthetic_analyze_result([
      'SYNTH-WORD-ORDER', '税込 120円/1 L', '計量 2.5 L'
    ])
    reversed_words.dig('pages', 0, 'words').reverse!

    results = [
      missing_words,
      overlapping_words,
      missing_component_words,
      outside_line_polygon,
      oversized_word_polygon,
      reversed_words
    ].map { |result| extract(result) }

    expect(results).to all(eq([]))
  end

  it 'requires every word polygon vertex to be inside its convex line polygon' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-WORD-POLYGON', '税込 120円/1 L', '計量 2.5 L'
    ])
    reference_line = analyze_result.dig('pages', 0, 'lines', 1)
    top = reference_line.fetch('polygon')[1]
    bottom = reference_line.fetch('polygon')[5]
    reference_line['polygon'] = [ 30, top, 240, top, 230, bottom, 20, bottom ]

    expect(extract(analyze_result)).to eq([])
  end

  it 'fails closed when the provider item count exceeds the existing bounded item contract' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-ITEM-BOUND', '税込 120円/1 L', '計量 2.5 L'
    ])
    header = analyze_result.dig('pages', 0, 'lines', 0)
    items = Array.new(101) do
      {
        'content' => header.fetch('content'),
        'spans' => [ header.fetch('spans').sole.deep_dup ],
        'valueObject' => {}
      }
    end
    analyze_result.dig('documents', 0, 'fields', 'Items')['valueArray'] = items

    expect(extract(analyze_result)).to eq([])
  end

  it 'keeps one true summary while a nonoverlapping item and later adjustment remain outside the block' do
    analyze_result = synthetic_analyze_result([
      'SYNTH-OTHER-ITEM', '税込 120円/1 L', '計量 2.5 L', '合計 300円', '値引 -10円'
    ])
    add_overlapping_item!(analyze_result, first_line_index: 0, last_line_index: 0)
    add_document_total!(analyze_result, line_index: 3)

    candidate = extract(analyze_result).sole

    expect(candidate[:summary_total_corroboration]).to include(
      summary_total: '300',
      rounding_matches: %w[floor half_up ceil]
    )
  end

  it 'fails closed for malformed polygons, spans, line overlap, and index type' do
    base = synthetic_analyze_result([
      'SYNTH-MALFORMED', '税込 120円/1 L', '計量 2.5 L'
    ])

    odd_polygon = base.deep_dup
    odd_polygon.dig('pages', 0, 'lines', 1, 'polygon').pop
    oversized_polygon = base.deep_dup
    oversized_polygon.dig('pages', 0, 'lines', 1, 'polygon').concat([ 20, 20 ])
    nonconvex_polygon = base.deep_dup
    nonconvex_polygon.dig('pages', 0, 'lines', 1)['polygon'] = [ 20, 30, 240, 42, 240, 30, 20, 42 ]
    negative_span = base.deep_dup
    negative_span.dig('pages', 0, 'lines', 1, 'spans', 0)['offset'] = -1
    oversized_span = base.deep_dup
    oversized_span.dig('pages', 0, 'lines', 1, 'spans', 0)['length'] = 10_000_001
    multiple_spans = base.deep_dup
    multiple_spans.dig('pages', 0, 'lines', 1, 'spans') << { 'offset' => 0, 'length' => 1 }
    nil_padded_spans = base.deep_dup
    nil_padded_spans.dig('pages', 0, 'lines', 1, 'spans').unshift(nil)
    nil_padded_documents = base.deep_dup
    nil_padded_documents.fetch('documents').unshift(nil)
    overlapping_lines = base.deep_dup
    overlapping_lines.dig('pages', 0, 'lines', 2, 'spans', 0)['offset'] =
      overlapping_lines.dig('pages', 0, 'lines', 1, 'spans', 0, 'offset')
    malformed_index_type = base.deep_dup
    malformed_index_type['stringIndexType'] = { 'value' => 'textElements' }

    results = [
      odd_polygon,
      oversized_polygon,
      nonconvex_polygon,
      negative_span,
      oversized_span,
      multiple_spans,
      nil_padded_spans,
      nil_padded_documents,
      overlapping_lines,
      malformed_index_type
    ].map { |result| extract(result) }

    expect(results).to all(eq([]))
  end

  it 'enforces page, line, word, text, and per-entry resource bounds' do
    too_many_lines = synthetic_analyze_result(Array.new(151) { |index| "NEUTRAL #{index}" })
    too_many_words = synthetic_analyze_result([
      'SYNTH-WORD-BOUND', '税込 120円/1 L', '計量 2.5 L'
    ])
    too_many_words.dig('pages', 0)['words'] = Array.new(4_801) do
      too_many_words.dig('pages', 0, 'words', 0).deep_dup
    end
    oversized_content = synthetic_analyze_result([
      'SYNTH-CONTENT-BOUND', '税込 120円/1 L', '計量 2.5 L'
    ])
    oversized_content['content'] = 'A' * 76_951
    oversized_line = synthetic_analyze_result([
      'A' * 513, '税込 120円/1 L', '計量 2.5 L'
    ])
    oversized_word = synthetic_analyze_result([
      'A' * 65, '税込 120円/1 L', '計量 2.5 L'
    ])

    results = [
      too_many_lines,
      too_many_words,
      oversized_content,
      oversized_line,
      oversized_word
    ].map { |result| extract(result) }

    expect(results).to all(eq([]))
  end

  it 'rejects oversized page dimensions and polygon coordinates before decimal conversion' do
    oversized_width = synthetic_analyze_result([
      'SYNTH-GEOMETRY-WIDTH', '税込 120円/1 L', '計量 2.5 L'
    ])
    oversized_width.dig('pages', 0)['width'] = 10**10_000

    oversized_coordinate = synthetic_analyze_result([
      'SYNTH-GEOMETRY-COORDINATE', '税込 120円/1 L', '計量 2.5 L'
    ])
    oversized_coordinate.dig('pages', 0, 'lines', 1, 'polygon')[2] = 10**10_000

    Timeout.timeout(2) do
      expect([ oversized_width, oversized_coordinate ].map { |result| extract(result) }).to all(eq([]))
    end
  end

  it 'rejects invalid encoding, NUL, and nonprinting control or bidi content' do
    invalid_encoding = synthetic_analyze_result([
      'SYNTH-ENCODING', '税込 120円/1 L', '計量 2.5 L'
    ])
    invalid_encoding['content'] = "\xFF".dup.force_encoding(Encoding::UTF_8)

    cases = [
      invalid_encoding,
      synthetic_analyze_result([ "SYNTH\0NUL", '税込 120円/1 L', '計量 2.5 L' ]),
      synthetic_analyze_result([ "SYNTH\u0007CONTROL", '税込 120円/1 L', '計量 2.5 L' ]),
      synthetic_analyze_result([ "SYNTH\u202ERLO", '税込 120円/1 L', '計量 2.5 L' ])
    ]

    expect(cases.map { |result| extract(result) }).to all(eq([]))
  end

  it 'bounds dense input without exploring a cross-product of line combinations' do
    lines = Array.new(50) do |index|
      [ "SYNTH-DENSE-#{index}", '税込 120円/1 L', '計量 2.5 L' ]
    end.flatten
    projection_calls = 0
    projection = lambda do |**attributes|
      projection_calls += 1
      ReceiptAmountService.reference_item_extension_projection(**attributes)
    end

    result = nil
    Timeout.timeout(2) do
      result = extract(synthetic_analyze_result(lines), projection:)
    end

    aggregate_failures do
      expect(result).to eq([])
      expect(projection_calls).to be <= 2
    end
  end

  it 'fails closed for duplicate candidate blocks' do
    candidates = extract_lines(
      'SYNTH-DUPLICATE',
      '税込 120円/1 L', '計量 2.5 L',
      '税込 120円/1 L', '計量 2.5 L'
    )

    expect(candidates).to eq([])
  end
end
