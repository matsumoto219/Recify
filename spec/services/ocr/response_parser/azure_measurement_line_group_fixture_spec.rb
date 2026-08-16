require 'rails_helper'

RSpec.describe 'synthetic Azure measurement line-group fixture' do
  LINE_GROUP_FIXTURE_CONTRACT_PATH = Rails.root.join(
    'spec/fixtures/ocr/ocr_azure_measurement_line_group_anonymized.json'
  )
  LINE_GROUP_FORBIDDEN_PROVIDER_FIELDS = %w[
    MerchantName MerchantAddress MerchantPhoneNumber TransactionDate TransactionTime
    ReceiptId TransactionId LoyaltyCard Vehicle Payment Payments PaymentMethods
  ].freeze

  def fixture
    @fixture ||= JSON.parse(LINE_GROUP_FIXTURE_CONTRACT_PATH.read)
  end

  def text_elements(value)
    value.scan(/\X/)
  end

  def text_element_slice(value, offset, length)
    text_elements(value).slice(offset, length)&.join
  end

  it 'contains only the anonymous Azure layout evidence needed by the contract' do
    analyze_result = fixture.fetch('analyzeResult')
    fields = analyze_result.dig('documents', 0, 'fields')

    aggregate_failures do
      expect(analyze_result).to include(
        'apiVersion' => '2024-11-30',
        'modelId' => 'prebuilt-receipt',
        'stringIndexType' => 'textElements'
      )
      expect(fields.dig('Items', 'valueArray')).to eq([])
      expect(fields.dig('Total', 'valueCurrency')).to eq(
        'amount' => 300,
        'currencyCode' => 'JPY'
      )
      expect(analyze_result.fetch('content')).to start_with("SYNTH-LAYOUT\n")
      expect(analyze_result.fetch('content')).not_to match(%r{https?://|@[a-z0-9.-]+\.[a-z]{2,}}i)
    end

    serialized = fixture.to_json
    LINE_GROUP_FORBIDDEN_PROVIDER_FIELDS.each do |field|
      expect(serialized).not_to include(%Q("#{field}"))
    end
  end

  it 'binds every line, word, and document Total to an exact textElements span' do
    analyze_result = fixture.fetch('analyzeResult')
    content = analyze_result.fetch('content')
    page = analyze_result.fetch('pages').sole
    total = analyze_result.dig('documents', 0, 'fields', 'Total')

    (page.fetch('lines') + page.fetch('words') + [ total ]).each do |entry|
      span = entry.fetch(entry.key?('spans') ? 'spans' : 'span')
      span = span.sole if span.is_a?(Array)

      aggregate_failures entry.fetch('content') do
        expect(text_element_slice(content, span.fetch('offset'), span.fetch('length'))).to eq(
          entry.fetch('content')
        )
        expect(span.fetch('offset')).to be >= 0
        expect(span.fetch('length')).to be_positive
      end
    end
  end

  it 'uses bounded four-point polygons and keeps the strict block consecutive' do
    page = fixture.dig('analyzeResult', 'pages', 0)
    lines = page.fetch('lines')

    (lines + page.fetch('words')).each do |entry|
      aggregate_failures entry.fetch('content') do
        expect(entry.fetch('polygon').size).to eq(8)
        expect(entry.fetch('polygon')).to all(be_a(Numeric))
      end
    end

    aggregate_failures do
      expect(lines.fetch(1).fetch('content')).to eq('税込 120円/1 L')
      expect(lines.fetch(2).fetch('content')).to eq('計量 2.5 L')
      expect(lines.fetch(1).dig('spans', 0, 'offset') + lines.fetch(1).dig('spans', 0, 'length') + 1)
        .to eq(lines.fetch(2).dig('spans', 0, 'offset'))
      expect(lines.fetch(3).fetch('content')).to eq('合計 300円')
    end
  end
end
