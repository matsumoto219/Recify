require 'rails_helper'

RSpec.describe 'Azure measurement line-group mapping' do
  LINE_GROUP_FIXTURE_PATH = Rails.root.join(
    'spec/fixtures/ocr/ocr_azure_measurement_line_group_anonymized.json'
  )

  def line_group_response
    JSON.parse(LINE_GROUP_FIXTURE_PATH.read)
  end

  def parse(response = line_group_response)
    Ocr::ResponseParser.new(
      response: response,
      provider: 'azure_document_intelligence',
      profile: ReceiptAnalysisProfiles.fetch('JPN')
    ).call
  end

  def text_element_length(value)
    value.scan(/\X/).length
  end

  def filter_reference_pricing_authority_fields(response, block_response: response)
    block_analyze_result = block_response.fetch('analyzeResult')
    reference_span = block_analyze_result.dig('pages', 0, 'lines', 1, 'spans', 0)
    quantity_span = block_analyze_result.dig('pages', 0, 'lines', 2, 'spans', 0)
    parser = Ocr::ResponseParser.new(
      response:,
      provider: 'azure_document_intelligence',
      profile: ReceiptAnalysisProfiles.fetch('JPN')
    )
    filtered = parser.send(
      :response_without_reference_pricing_block_fields,
      response,
      [
        {
          source_kind: 'azure_line_group',
          block_provider_span_start: reference_span.fetch('offset'),
          block_provider_span_end: quantity_span.fetch('offset') + quantity_span.fetch('length')
        }
      ]
    )

    filtered.dig('analyzeResult', 'documents', 0, 'fields')
  end

  def summary_currency_field(response)
    summary_word = response.dig('analyzeResult', 'pages', 0, 'words').last
    {
      'type' => 'currency',
      'content' => summary_word.fetch('content'),
      'spans' => [ summary_word.fetch('span').deep_dup ],
      'boundingRegions' => [
        {
          'pageNumber' => 1,
          'polygon' => summary_word.fetch('polygon').deep_dup
        }
      ],
      'valueCurrency' => { 'amount' => 300, 'currencyCode' => 'JPY' }
    }
  end

  def multi_span_tax_detail_response
    response = rewrite_page_lines!(
      line_group_response.deep_dup,
      [
        'SYNTH-AUTHORITY',
        '税込 120円/1 L',
        '計量 2.5 L',
        '10%対象 270円',
        '内税 30円',
        '合計 300円'
      ]
    )
    analyze_result = response.fetch('analyzeResult')
    lines = analyze_result.dig('pages', 0, 'lines')
    first_line = lines.fetch(3)
    second_line = lines.fetch(4)
    analyze_result.dig('documents', 0, 'fields')['TaxDetails'] = {
      'type' => 'array',
      'valueArray' => [
        {
          'type' => 'object',
          'content' => [ first_line.fetch('content'), second_line.fetch('content') ].join("\n"),
          'spans' => [
            first_line.fetch('spans').sole.deep_dup,
            second_line.fetch('spans').sole.deep_dup
          ],
          'boundingRegions' => [
            {
              'pageNumber' => 1,
              'polygon' => [ 20, 58, 240, 58, 240, 102, 20, 102 ]
            }
          ],
          'valueObject' => {
            'Description' => {
              'type' => 'string',
              'content' => first_line.fetch('content'),
              'spans' => first_line.fetch('spans').map(&:deep_dup),
              'valueString' => first_line.fetch('content')
            },
            'Amount' => {
              'type' => 'currency',
              'content' => second_line.fetch('content'),
              'spans' => second_line.fetch('spans').map(&:deep_dup),
              'valueCurrency' => { 'amount' => 30, 'currencyCode' => 'JPY' }
            }
          }
        }
      ]
    }
    response
  end

  def multi_span_authority_response(span_count:, fragment: nil)
    authority_lines = Array.new(span_count) { |index| fragment || "A#{index}" }
    response = rewrite_page_lines!(
      line_group_response.deep_dup,
      [ 'SYNTH-AUTHORITY', '税込 120円/1 L', '計量 2.5 L', *authority_lines, '合計 300円' ]
    )
    analyze_result = response.fetch('analyzeResult')
    page = analyze_result.dig('pages', 0)
    page['height'] = [ page.fetch('height'), (authority_lines.size + 5) * 16 ].max
    lines = page.fetch('lines').slice(3, authority_lines.size)
    analyze_result.dig('documents', 0, 'fields')['Total'] = {
      'type' => 'string',
      'content' => lines.map { |line| line.fetch('content') }.join("\n"),
      'spans' => lines.map { |line| line.fetch('spans').sole.deep_dup },
      'boundingRegions' => [
        { 'pageNumber' => 1, 'polygon' => [ 20, 58, 240, 58, 240, 74, 20, 74 ] }
      ],
      'valueString' => authority_lines.join("\n")
    }
    response
  end

  def rewrite_page_lines!(response, lines)
    analyze_result = response.fetch('analyzeResult')
    cursor = 0
    words = []
    page_lines = lines.each_with_index.map do |line, line_index|
      y = 10 + (line_index * 16)
      line.to_enum(:scan, /\S+/).each_with_index do |word, word_index|
        match = Regexp.last_match
        word_offset = cursor + text_element_length(line[0...match.begin(0)].to_s)
        x = 20 + (word_index * 45)
        words << {
          'content' => word,
          'polygon' => [ x, y, x + 40, y, x + 40, y + 12, x, y + 12 ],
          'span' => { 'offset' => word_offset, 'length' => text_element_length(word) }
        }
      end

      line_length = text_element_length(line)
      entry = {
        'content' => line,
        'polygon' => [ 20, y, 240, y, 240, y + 12, 20, y + 12 ],
        'spans' => [ { 'offset' => cursor, 'length' => line_length } ]
      }
      cursor += line_length + 1
      entry
    end
    analyze_result['content'] = lines.join("\n")
    analyze_result.dig('pages', 0)['lines'] = page_lines
    analyze_result.dig('pages', 0)['words'] = words

    summary_line = page_lines.last
    amount = summary_line.fetch('content').scan(/\d[\d,]*/).sole
    amount_offset = summary_line.fetch('content').index(amount)
    summary_start = summary_line.dig('spans', 0, 'offset')
    analyze_result.dig('documents', 0, 'fields')['Total'] = {
      'type' => 'currency',
      'content' => amount,
      'spans' => [
        {
          'offset' => summary_start + text_element_length(summary_line.fetch('content')[0...amount_offset]),
          'length' => text_element_length(amount)
        }
      ],
      'valueCurrency' => { 'amount' => amount.delete(',').to_i, 'currencyCode' => 'JPY' }
    }
    response
  end

  it 'uses the strict line group only when Azure Items has no candidate' do
    result = parse
    candidate = result.dig(:candidates, :reference_pricing_candidates).sole

    aggregate_failures do
      expect(result[:success]).to be(true)
      expect(result.dig(:candidates, :items)).to eq([])
      expect(result.dig(:candidates, :total_amount)).to eq(300)
      expect(candidate).to include(
        candidate_id: 'azure_line_group_p0_l1_l2_reference_pricing',
        source_kind: 'azure_line_group',
        validation_state: 'valid',
        printed_line_total: nil
      )
      expect(candidate[:summary_total_corroboration]).to include(
        projected_amount: 300,
        summary_total: '300',
        rounding_matches: %w[floor half_up ceil]
      )
      expect(candidate.keys).not_to include(
        :pricing_source_kind,
        :price,
        :line_total,
        :original_line_total,
        :reference_price_amount,
        :reference_quantity_unit_code
      )
    end
  end

  it 'keeps the existing Azure Items candidate path authoritative over the fallback' do
    response = line_group_response.deep_dup
    analyze_result = response.fetch('analyzeResult')
    content = analyze_result.fetch('content')
    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: 'textElements')
    description = 'SYNTH-LAYOUT'
    price_content = '税込 120円/1 L'
    quantity_content = '計量 2.5 L'
    total_content = '合計 300円'
    item = {
      'content' => content,
      'spans' => [ { 'offset' => 0, 'length' => mapper.length(content) } ],
      'valueObject' => {
        'Description' => {
          'content' => description,
          'spans' => [ { 'offset' => content.index(description), 'length' => mapper.length(description) } ],
          'valueString' => description
        },
        'Price' => {
          'content' => price_content,
          'spans' => [ { 'offset' => content.index(price_content), 'length' => mapper.length(price_content) } ],
          'valueCurrency' => { 'amount' => 120, 'currencyCode' => 'JPY' }
        },
        'Quantity' => {
          'content' => quantity_content,
          'spans' => [ { 'offset' => content.index(quantity_content), 'length' => mapper.length(quantity_content) } ],
          'valueNumber' => 2.5
        },
        'QuantityUnit' => {
          'content' => quantity_content,
          'spans' => [ { 'offset' => content.index(quantity_content), 'length' => mapper.length(quantity_content) } ],
          'valueString' => 'L'
        },
        'TotalPrice' => {
          'content' => total_content,
          'spans' => [ { 'offset' => content.index(total_content), 'length' => mapper.length(total_content) } ],
          'valueCurrency' => { 'amount' => 300, 'currencyCode' => 'JPY' }
        }
      }
    }
    response.dig('analyzeResult', 'documents', 0, 'fields', 'Items')['valueArray'] = [ item ]

    result = parse(response)
    candidates = result.dig(:candidates, :reference_pricing_candidates)

    aggregate_failures do
      expect(candidates.map { |candidate| candidate[:candidate_id] }).to eq(
        [ 'azure_items_0_reference_pricing' ]
      )
      expect(candidates).to all(satisfy { |candidate| !candidate.key?(:source_kind) })
      expect(result.dig(:candidates, :items).size).to eq(1)
      expect(result.dig(:candidates, :total_amount)).to eq(300)
    end
  end

  it 'rejects the fallback when an Azure Item child span escapes its parent into the strict block' do
    response = line_group_response.deep_dup
    analyze_result = response.fetch('analyzeResult')
    header_line = analyze_result.dig('pages', 0, 'lines', 0)
    reference_line = analyze_result.dig('pages', 0, 'lines', 1)
    price_offset = reference_line.dig('spans', 0, 'offset') +
      text_element_length(reference_line.fetch('content')[0...reference_line.fetch('content').index('120')])
    analyze_result.dig('documents', 0, 'fields', 'Items')['valueArray'] = [
      {
        'content' => header_line.fetch('content'),
        'spans' => header_line.fetch('spans').map(&:deep_dup),
        'valueObject' => {
          'Description' => {
            'content' => header_line.fetch('content'),
            'spans' => header_line.fetch('spans').map(&:deep_dup),
            'valueString' => header_line.fetch('content')
          },
          'Price' => {
            'content' => '120',
            'spans' => [ { 'offset' => price_offset, 'length' => 3 } ],
            'valueCurrency' => { 'amount' => 120, 'currencyCode' => 'JPY' }
          }
        }
      }
    ]

    result = parse(response)
    params = Analysis::ReceiptBuildParamsService.call(ocr_result: result, ai_result: nil)

    aggregate_failures do
      expect(result.dig(:candidates, :reference_pricing_candidates)).to eq([])
      expect(result.dig(:candidates, :items).sole).to include(price: 120)
      expect(params.fetch(:receipt_items_attributes).sole).to include(price: 120, line_total: 120)
    end
  end

  it 'does not treat a document Total span inside the Measurement block as the receipt total' do
    response = line_group_response.deep_dup
    total = response.dig('analyzeResult', 'documents', 0, 'fields', 'Total')
    total.merge!(
      'content' => '120',
      'spans' => [ { 'offset' => 16, 'length' => 3 } ],
      'valueCurrency' => { 'amount' => 120, 'currencyCode' => 'JPY' }
    )

    result = parse(response)
    candidate = result.dig(:candidates, :reference_pricing_candidates).sole

    aggregate_failures do
      expect(result.dig(:candidates, :total_amount)).to eq(300)
      expect(candidate[:printed_line_total]).to be_nil
      expect(candidate.dig(:summary_total_corroboration, :summary_total)).to eq('300')
    end
  end

  it 'fails closed when the only document Total overlaps the Measurement block' do
    response = line_group_response.deep_dup
    analyze_result = response.fetch('analyzeResult')
    removed_line = analyze_result.dig('pages', 0, 'lines').pop
    removed_offset = removed_line.dig('spans', 0, 'offset')
    analyze_result.dig('pages', 0, 'words').reject! do |word|
      word.dig('span', 'offset') >= removed_offset
    end
    analyze_result['content'] = analyze_result.dig('pages', 0, 'lines').map { |line| line.fetch('content') }.join("\n")
    total = analyze_result.dig('documents', 0, 'fields', 'Total')
    total.merge!(
      'content' => '120',
      'spans' => [ { 'offset' => 16, 'length' => 3 } ],
      'valueCurrency' => { 'amount' => 120, 'currencyCode' => 'JPY' }
    )

    result = parse(response)
    candidate = result.dig(:candidates, :reference_pricing_candidates).sole

    aggregate_failures do
      expect(result.dig(:candidates, :total_amount)).to be_nil
      expect(candidate).to include(validation_state: 'valid', printed_line_total: nil)
      expect(candidate[:summary_total_corroboration]).to be_nil
    end
  end

  it 'preserves one explicit summary line when the document Total span is absent' do
    responses = [ :absent, :empty ].map do |span_state|
      response = line_group_response.deep_dup
      total = response.dig('analyzeResult', 'documents', 0, 'fields', 'Total')
      span_state == :absent ? total.delete('spans') : total['spans'] = []
      response
    end

    responses.each do |response|
      result = parse(response)
      candidate = result.dig(:candidates, :reference_pricing_candidates).sole

      aggregate_failures do
        expect(result.dig(:candidates, :total_amount)).to eq(300)
        expect(candidate[:printed_line_total]).to be_nil
        expect(candidate[:summary_total_corroboration]).to include(
          summary_total: '300',
          rounding_matches: %w[floor half_up ceil]
        )
      end
    end
  end

  it 'does not promote a net reference-price component to the receipt subtotal' do
    response = line_group_response.deep_dup
    analyze_result = response.fetch('analyzeResult')
    analyze_result['content'] = analyze_result.fetch('content').sub('税込', '税抜')
    reference_line = analyze_result.dig('pages', 0, 'lines', 1)
    reference_line['content'] = reference_line.fetch('content').sub('税込', '税抜')
    tax_word = analyze_result.dig('pages', 0, 'words').find { |word| word['content'] == '税込' }
    tax_word['content'] = '税抜'

    result = parse(response)
    candidate = result.dig(:candidates, :reference_pricing_candidates).sole

    aggregate_failures do
      expect(candidate).to include(
        validation_state: 'valid',
        reference_price_tax_inclusion: 'net',
        printed_line_total: nil
      )
      expect(result.dig(:candidates, :subtotal_amount)).to be_nil
      expect(result.dig(:candidates, :total_amount)).to eq(300)
    end
  end

  it 'keeps a post-discount basis out of receipt adjustment persistence' do
    response = rewrite_page_lines!(
      line_group_response.deep_dup,
      [
        'SYNTH-BASIS',
        '値引後 税込 120円/1 L',
        '計量 2.5 L',
        '合計 300円'
      ]
    )

    result = parse(response)
    candidate = result.dig(:candidates, :reference_pricing_candidates).sole
    params = Analysis::ReceiptBuildParamsService.call(ocr_result: result, ai_result: nil)

    aggregate_failures do
      expect(candidate).to include(validation_state: 'valid', printed_line_total: nil)
      expect(result.dig(:candidates, :adjustment_candidates)).to eq([])
      expect(params.fetch(:receipt_adjustments_attributes)).to eq([])
      expect(params.fetch(:receipt_items_attributes)).to eq([])
    end
  end

  it 'keeps structured fields whose spans belong to the strict block out of receipt authority' do
    response = rewrite_page_lines!(
      line_group_response.deep_dup,
      [
        'SYNTH-AUTHORITY',
        '検証品A03 税込10% 120円/1 L',
        '計量 2.5 L',
        '合計 300円'
      ]
    )
    analyze_result = response.fetch('analyzeResult')
    fields = analyze_result.dig('documents', 0, 'fields')
    reference_line = analyze_result.dig('pages', 0, 'lines', 1)
    reference_start = reference_line.dig('spans', 0, 'offset')
    reference_content = reference_line.fetch('content')
    span_for = lambda do |lexeme|
      byte_offset = reference_content.index(lexeme)
      {
        'offset' => reference_start + text_element_length(reference_content.byteslice(0, byte_offset)),
        'length' => text_element_length(lexeme)
      }
    end
    identifier_span = span_for.call('検証品A03')
    rate_span = span_for.call('10%')
    price_span = span_for.call('120')

    fields.merge!(
      'MerchantName' => {
        'type' => 'string', 'content' => '検証品A03', 'spans' => [ identifier_span ],
        'valueString' => '検証品A03'
      },
      'MerchantAddress' => {
        'type' => 'string', 'content' => '検証品A03', 'spans' => [ identifier_span ],
        'valueString' => '検証品A03'
      },
      'MerchantPhoneNumber' => {
        'type' => 'phoneNumber', 'content' => '120', 'spans' => [ price_span ],
        'valuePhoneNumber' => '120'
      },
      'Subtotal' => {
        'type' => 'currency', 'content' => '120', 'spans' => [ price_span ],
        'valueCurrency' => { 'amount' => 120, 'currencyCode' => 'JPY' }
      },
      'TotalTax' => {
        'type' => 'currency', 'content' => '120', 'spans' => [ price_span ],
        'valueCurrency' => { 'amount' => 120, 'currencyCode' => 'JPY' }
      },
      'TaxDetails' => {
        'type' => 'array',
        'valueArray' => [
          {
            'valueObject' => {
              'Rate' => {
                'type' => 'number', 'content' => '10%', 'spans' => [ rate_span ], 'valueNumber' => 10
              },
              'Amount' => {
                'type' => 'currency', 'content' => '120', 'spans' => [ price_span ],
                'valueCurrency' => { 'amount' => 120, 'currencyCode' => 'JPY' }
              }
            }
          }
        ]
      },
      'Payments' => {
        'type' => 'array',
        'valueArray' => [
          {
            'valueObject' => {
              'Method' => {
                'type' => 'string', 'content' => '検証品A03', 'spans' => [ identifier_span ],
                'valueString' => '検証品A03'
              },
              'Amount' => {
                'type' => 'currency', 'content' => '120', 'spans' => [ price_span ],
                'valueCurrency' => { 'amount' => 120, 'currencyCode' => 'JPY' }
              }
            }
          }
        ]
      },
      'PaymentMethods' => {
        'type' => 'string', 'content' => '検証品A03', 'spans' => [ identifier_span ],
        'valueString' => '検証品A03'
      }
    )

    result = parse(response)
    candidate = result.dig(:candidates, :reference_pricing_candidates).sole
    candidates = result.fetch(:candidates)
    params = Analysis::ReceiptBuildParamsService.call(ocr_result: result, ai_result: nil)

    aggregate_failures do
      expect(candidate).to include(source_kind: 'azure_line_group', validation_state: 'valid')
      expect(candidates[:store_name]).not_to eq('検証品A03')
      expect(candidates.values_at(:store_address, :store_phone_number)).to eq([ nil, nil ])
      expect(candidates.values_at(:subtotal_amount, :tax_amount, :tax_rate)).to eq([ nil, nil, nil ])
      expect(candidates.values_at(:payment_candidates, :payments, :tax_details)).to eq([ [], [], [] ])
      expect(candidates.values_at(:items, :adjustment_candidates)).to eq([ [], [] ])
      receipt_attributes = params.fetch(:receipt_attributes)
      expect(receipt_attributes[:store_name]).not_to eq('検証品A03')
      expect(receipt_attributes.values_at(
        :store_address,
        :store_phone_number,
        :subtotal_amount,
        :tax_amount,
        :tax_rate
      )).to eq([ nil, nil, nil, nil, nil ])
      expect(params.values_at(:receipt_payments_attributes, :receipt_tax_details_attributes)).to eq([ [], [] ])
      expect(params.values_at(:receipt_items_attributes, :receipt_adjustments_attributes)).to eq([ [], [] ])
    end
  end

  it 'drops an authority field when any nested span-only node claims the strict block' do
    response = line_group_response.deep_dup
    analyze_result = response.fetch('analyzeResult')
    header_line = analyze_result.dig('pages', 0, 'lines', 0)
    reference_line = analyze_result.dig('pages', 0, 'lines', 1)
    analyze_result.dig('documents', 0, 'fields')['MerchantAddress'] = {
      'type' => 'string',
      'content' => header_line.fetch('content'),
      'spans' => header_line.fetch('spans').map(&:deep_dup),
      'valueString' => header_line.fetch('content'),
      'mystery' => {
        'spans' => reference_line.fetch('spans').map(&:deep_dup)
      }
    }

    result = parse(response)

    aggregate_failures do
      expect(result.dig(:candidates, :reference_pricing_candidates).sole).to include(
        source_kind: 'azure_line_group', validation_state: 'valid'
      )
      expect(result.dig(:candidates, :store_address)).to be_nil
    end
  end

  it 'accepts bounded Azure boundingRegions metadata on receipt authority fields outside the strict block' do
    response = line_group_response.deep_dup
    fields = response.dig('analyzeResult', 'documents', 0, 'fields')
    expect(filter_reference_pricing_authority_fields(response)).to have_key('Total')

    currency_field = summary_currency_field(response)
    tax_detail = {
      'type' => 'object',
      'content' => currency_field.fetch('content'),
      'spans' => currency_field.fetch('spans').map(&:deep_dup),
      'boundingRegions' => currency_field.fetch('boundingRegions').map(&:deep_dup),
      'valueObject' => {
        'Amount' => currency_field.deep_dup
      }
    }
    fields.merge!(
      'Total' => currency_field.deep_dup,
      'Subtotal' => currency_field.deep_dup,
      'TotalTax' => currency_field.deep_dup,
      'TaxDetails' => { 'type' => 'array', 'valueArray' => [ tax_detail ] }
    )

    filtered_fields = filter_reference_pricing_authority_fields(response)

    expect(filtered_fields.keys).to include('Total', 'Subtotal', 'TotalTax', 'TaxDetails')
  end

  it 'accepts an ordered bounded multi-span TaxDetails parent outside the strict block' do
    response = multi_span_tax_detail_response

    expect(filter_reference_pricing_authority_fields(response)).to have_key('TaxDetails')
  end

  it 'bounds authority multi-spans and rejects reordered, overlapping, mismatched, and block-owned spans' do
    maximum = multi_span_authority_response(
      span_count: Ocr::ResponseParser::MAX_REFERENCE_PRICING_AUTHORITY_SPANS
    )
    excessive = multi_span_authority_response(
      span_count: Ocr::ResponseParser::MAX_REFERENCE_PRICING_AUTHORITY_SPANS + 1
    )
    reordered = multi_span_tax_detail_response
    reordered_parent = reordered.dig('analyzeResult', 'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0)
    reordered_parent['spans'].reverse!
    overlapping = multi_span_tax_detail_response
    overlapping_parent = overlapping.dig('analyzeResult', 'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0)
    overlapping_parent['spans'].last['offset'] = overlapping_parent.dig('spans', 0, 'offset') + 1
    mismatched = multi_span_tax_detail_response
    mismatched.dig(
      'analyzeResult', 'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0
    )['content'] += 'x'
    block_owned = multi_span_tax_detail_response
    block_parent = block_owned.dig('analyzeResult', 'documents', 0, 'fields', 'TaxDetails', 'valueArray', 0)
    reference_line = block_owned.dig('analyzeResult', 'pages', 0, 'lines', 1)
    outside_line = block_owned.dig('analyzeResult', 'pages', 0, 'lines', 3)
    block_parent['spans'] = [
      reference_line.fetch('spans').sole.deep_dup,
      outside_line.fetch('spans').sole.deep_dup
    ]
    block_parent['content'] = [
      reference_line.fetch('content'),
      outside_line.fetch('content')
    ].join("\n")
    oversized = multi_span_authority_response(span_count: 1, fragment: 'x' * 513)

    aggregate_failures do
      expect(filter_reference_pricing_authority_fields(maximum)).to have_key('Total')
      expect(filter_reference_pricing_authority_fields(excessive)).not_to have_key('Total')
      expect(filter_reference_pricing_authority_fields(reordered)).not_to have_key('TaxDetails')
      expect(filter_reference_pricing_authority_fields(overlapping)).not_to have_key('TaxDetails')
      expect(filter_reference_pricing_authority_fields(mismatched)).not_to have_key('TaxDetails')
      expect(filter_reference_pricing_authority_fields(block_owned)).not_to have_key('TaxDetails')
      expect(filter_reference_pricing_authority_fields(oversized)).not_to have_key('Total')
    end
  end

  it 'fails closed for malformed boundingRegions, unknown primitive arrays, and overlapping authority spans' do
    response = line_group_response.deep_dup
    valid_field = summary_currency_field(response)
    reference_word = response.dig('analyzeResult', 'pages', 0, 'words', 2)
    invalid_fields = {
      'empty regions' => valid_field.deep_dup.tap { |field| field['boundingRegions'] = [] },
      'unknown page' => valid_field.deep_dup.tap do |field|
        field.dig('boundingRegions', 0)['pageNumber'] = 2
      end,
      'malformed polygon' => valid_field.deep_dup.tap do |field|
        field.dig('boundingRegions', 0)['polygon'] = [ 54, 130, 94 ]
      end,
      'out-of-bounds polygon' => valid_field.deep_dup.tap do |field|
        field.dig('boundingRegions', 0, 'polygon')[2] = 301
      end,
      'crossed polygon' => valid_field.deep_dup.tap do |field|
        field.dig('boundingRegions', 0)['polygon'] = [ 54, 130, 94, 146, 94, 130, 54, 146 ]
      end,
      'unknown region key' => valid_field.deep_dup.tap do |field|
        field.dig('boundingRegions', 0)['providerExtension'] = 'unsupported'
      end,
      'oversized region' => valid_field.deep_dup.tap do |field|
        100.times { |index| field.dig('boundingRegions', 0)["providerExtension#{index}"] = index }
      end,
      'unknown primitive array' => valid_field.deep_dup.merge('providerExtension' => [ 1 ]),
      'overlapping span' => valid_field.deep_dup.tap do |field|
        field['content'] = reference_word.fetch('content')
        field['spans'] = [ reference_word.fetch('span').deep_dup ]
      end
    }

    invalid_fields.each do |label, field|
      candidate = response.deep_dup
      candidate.dig('analyzeResult', 'documents', 0, 'fields')['Total'] = field

      expect(filter_reference_pricing_authority_fields(candidate, block_response: response)).not_to have_key('Total'), label
    end
  end

  it 'fails closed when page geometry is missing, oversized, or has duplicate page numbers' do
    response = line_group_response.deep_dup
    response.dig('analyzeResult', 'documents', 0, 'fields')['Total'] = summary_currency_field(response)
    invalid_pages = {
      'missing pages' => nil,
      'missing dimensions' => [ { 'pageNumber' => 1 } ],
      'oversized dimensions' => response.dig('analyzeResult', 'pages').deep_dup.tap do |pages|
        pages.sole['width'] = 10_001
      end,
      'duplicate page number' => response.dig('analyzeResult', 'pages').deep_dup.then do |pages|
        pages + [ pages.sole.deep_dup ]
      end
    }

    invalid_pages.each do |label, pages|
      candidate = response.deep_dup
      candidate.dig('analyzeResult')['pages'] = pages

      expect(filter_reference_pricing_authority_fields(candidate, block_response: response)).not_to have_key('Total'), label
    end
  end

  it 'does not extend the line-group mapping to the legacy top-level fields fallback' do
    response = line_group_response.deep_dup
    document = response.dig('analyzeResult', 'documents', 0)
    document.delete('fields')
    header_line = response.dig('analyzeResult', 'pages', 0, 'lines', 0)
    header_span = header_line.fetch('spans').sole
    response['fields'] = {
      'Items' => {
        'type' => 'array',
        'valueArray' => [
          {
            'content' => header_line.fetch('content'),
            'spans' => [ header_span.deep_dup ],
            'valueObject' => {
              'Description' => {
                'type' => 'string',
                'content' => header_line.fetch('content'),
                'spans' => [ header_span.deep_dup ],
                'valueString' => header_line.fetch('content')
              },
              'Price' => {
                'type' => 'currency', 'content' => '120', 'spans' => [ { 'offset' => 16, 'length' => 3 } ],
                'valueCurrency' => { 'amount' => 120, 'currencyCode' => 'JPY' }
              }
            }
          }
        ]
      }
    }

    result = parse(response)
    params = Analysis::ReceiptBuildParamsService.call(ocr_result: result, ai_result: nil)

    aggregate_failures do
      expect(result.dig(:candidates, :reference_pricing_candidates)).to eq([])
      expect(result.dig(:candidates, :items).sole).to include(
        raw_text: header_line.fetch('content'),
        price: 120
      )
      expect(params.fetch(:receipt_items_attributes).sole).to include(
        raw_text: header_line.fetch('content'),
        price: 120,
        line_total: 120
      )
    end
  end
end
