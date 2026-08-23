require 'rails_helper'

RSpec.describe Ocr::ResponseParser::ReferencePricingLineGroupExtractor do
  DESTINATION_FIXTURE_PATH = Rails.root.join(
    'spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json'
  )
  DESTINATION_LESS_FIXTURE_PATH = Rails.root.join(
    'spec/fixtures/ocr/ocr_azure_measurement_line_group_anonymized.json'
  )

  def text_element_length(value)
    value.scan(/\X/).length
  end

  def multi_block_analyze_result
    lines = [
      {
        content: 'SYNTH-LAYOUT',
        words: [ [ 'SYNTH-LAYOUT', 20, 150 ] ]
      },
      {
        content: '検証品A01 税込 120円/1 L',
        words: [
          [ '検証', 20, 36 ], [ '品', 39, 47 ], [ 'A', 50, 58 ], [ '01', 61, 70 ],
          [ '税', 76, 85 ], [ '込', 89, 98 ], [ '120円/1', 116, 184 ], [ 'L', 190, 202 ]
        ]
      },
      {
        content: '計量 2.5 L',
        words: [ [ '計量', 20, 48 ], [ '2.5', 54, 84 ], [ 'L', 90, 102 ] ]
      },
      {
        content: '検証品B02 税込 150円/1 L',
        words: [
          [ '検証', 20, 36 ], [ '品', 39, 47 ], [ 'B', 50, 58 ], [ '02', 61, 70 ],
          [ '税', 76, 85 ], [ '込', 89, 98 ], [ '150円/1', 116, 184 ], [ 'L', 190, 202 ]
        ]
      },
      {
        content: '計量 1.5 L',
        words: [ [ '計量', 20, 48 ], [ '1.5', 54, 84 ], [ 'L', 90, 102 ] ]
      },
      {
        content: '合計 525円',
        words: [ [ '合計', 20, 48 ], [ '525円', 54, 94 ] ]
      }
    ]
    content = lines.pluck(:content).join("\n")
    cursor = 0
    page_lines = []
    page_words = []

    lines.each_with_index do |line, line_index|
      y = 10 + (line_index * 22)
      line_start = cursor
      line_length = text_element_length(line.fetch(:content))
      page_lines << {
        'content' => line.fetch(:content),
        'polygon' => [ 20, y, 220, y, 220, y + 16, 20, y + 16 ],
        'spans' => [ { 'offset' => line_start, 'length' => line_length } ]
      }

      search_offset = 0
      line.fetch(:words).each do |word, left, right|
        character_offset = line.fetch(:content).index(word, search_offset)
        raise "missing synthetic word" if character_offset.nil?

        page_words << {
          'content' => word,
          'polygon' => [ left, y, right, y, right, y + 16, left, y + 16 ],
          'confidence' => 0.99,
          'span' => {
            'offset' => line_start + text_element_length(line.fetch(:content)[0...character_offset]),
            'length' => text_element_length(word)
          }
        }
        search_offset = character_offset + word.length
      end
      cursor += line_length + 1
    end

    summary_line = page_lines.last
    summary_amount_offset = summary_line.fetch('content').index('525')
    summary_amount_start = summary_line.dig('spans', 0, 'offset') +
      text_element_length(summary_line.fetch('content')[0...summary_amount_offset])

    {
      'apiVersion' => '2024-11-30',
      'modelId' => 'prebuilt-receipt',
      'stringIndexType' => 'textElements',
      'content' => content,
      'pages' => [
        {
          'pageNumber' => 1,
          'width' => 300,
          'height' => 220,
          'unit' => 'pixel',
          'words' => page_words,
          'lines' => page_lines
        }
      ],
      'documents' => [
        {
          'docType' => 'receipt.retailMeal',
          'fields' => {
            'Items' => { 'type' => 'array', 'valueArray' => [] },
            'Total' => {
              'type' => 'currency',
              'content' => '525円',
              'spans' => [ { 'offset' => summary_amount_start, 'length' => 4 } ],
              'valueCurrency' => { 'amount' => 525, 'currencyCode' => 'JPY' }
            }
          }
        }
      ]
    }
  end

  def evidence_options(analyze_result = multi_block_analyze_result)
    described_class.evidence_options(
      analyze_result:,
      profile: ReceiptAnalysisProfiles.fetch('JPN'),
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    )
  end

  it 'keeps A1 globally unique while exposing deterministic, pair-local A2 options' do
    analyze_result = multi_block_analyze_result

    a1_candidates = described_class.call(
      analyze_result:,
      profile: ReceiptAnalysisProfiles.fetch('JPN'),
      projection: ReceiptAmountService.method(:reference_item_extension_projection)
    )
    first = evidence_options(analyze_result)
    second = evidence_options(analyze_result.deep_dup)

    aggregate_failures do
      expect(a1_candidates).to eq([])
      expect(first).to eq(second)
      expect(first.size).to eq(2)
      expect(first.pluck(:candidate_id)).to all(match(/\Aazure_line_group_evidence_v1_[0-9a-f]{64}\z/))
      expect(first.pluck(:candidate_id).uniq.size).to eq(2)
      expect(first.pluck(:destination_id).uniq.size).to eq(2)
      expect(first.pluck(:source_kind)).to eq(%w[azure_line_group azure_line_group])
      expect(first.pluck(:reference_line_index)).to eq([ 1, 3 ])
      expect(first.pluck(:purchased_quantity_line_index)).to eq([ 2, 4 ])
    end
  end

  it 'adds options to the parser result without changing the current candidate selection' do
    result = Ocr::ResponseParser.new(
      response: { 'status' => 'succeeded', 'analyzeResult' => multi_block_analyze_result },
      provider: 'azure_document_intelligence'
    ).call

    aggregate_failures do
      expect(result.dig(:candidates, :reference_pricing_candidates)).to eq([])
      expect(result.dig(:evidence_options, :reference_pricing).size).to eq(2)
      expect(result.dig(:evidence_options, :reference_pricing)).to all(
        include(source_kind: 'azure_line_group')
      )
    end
  end

  it 'emits only bounded structural handles and never carries numeric or text authority' do
    option = evidence_options.first

    aggregate_failures do
      expect(option.keys).to contain_exactly(
        :candidate_id,
        :destination_id,
        :source_kind,
        :provider_model_id,
        :provider_api_version,
        :string_index_type,
        :validation_state,
        :validation_contract_version,
        :analysis_profile_country_code,
        :page_index,
        :reference_line_index,
        :purchased_quantity_line_index,
        :handles
      )
      expect(option.fetch(:handles).pluck(:role)).to eq(%w[
        product_destination
        reference_price
        reference_quantity
        purchased_quantity
        tax_inclusion
      ])
      expect(option.fetch(:handles)).to all(include(
        :handle_id,
        :role,
        :source_field_path,
        :page_index,
        :line_index,
        :string_index_type,
        :provider_span_start,
        :provider_span_end
      ))

      serialized = JSON.generate(option)
      expect(serialized).not_to match(/検証|税込|計量/)
      expect(option.keys).not_to include(:amount, :quantity, :unit, :unit_code, :tax, :line_total)
      expect(option.fetch(:handles).flat_map(&:keys)).not_to include(
        :content,
        :raw_text,
        :amount,
        :quantity,
        :unit,
        :unit_code,
        :tax,
        :line_total,
        :polygon
      )
    end
  end

  it 'fails closed rather than exposing a partial option set above the bound' do
    stub_const("#{described_class}::MAX_EVIDENCE_OPTIONS", 1)

    expect(evidence_options).to eq([])
  end

  it 'does not expose package, discount, malformed, or destination-less blocks as options' do
    package_result = JSON.parse(DESTINATION_FIXTURE_PATH.read).fetch('analyzeResult')
    package_result['content'].sub!('検証品A01', '内容量3個X')
    package_result.dig('pages', 0, 'lines', 1)['content'].sub!('検証品A01', '内容量3個X')
    package_words = package_result.dig('pages', 0, 'words').slice(1, 4)
    package_words.zip(%w[内容 量 3 個X]).each do |word, content|
      word['content'] = content
    end

    discount_result = multi_block_analyze_result
    discount_result['content'].sub!('検証品A01 税込', '検証品A01 値引')
    discount_result.dig('pages', 0, 'lines', 1)['content'].sub!('税込', '値引')
    discount_result.dig('pages', 0, 'words', 5)['content'] = '値'
    discount_result.dig('pages', 0, 'words', 6)['content'] = '引'

    malformed_result = multi_block_analyze_result
    malformed_result.dig('pages', 0, 'lines', 1, 'polygon').pop

    destination_less = JSON.parse(DESTINATION_LESS_FIXTURE_PATH.read).fetch('analyzeResult')

    aggregate_failures do
      expect(evidence_options(package_result)).to eq([])
      expect(evidence_options(discount_result)).to eq([])
      expect(evidence_options(malformed_result)).to eq([])
      expect(evidence_options(destination_less)).to eq([])
    end
  end
end
