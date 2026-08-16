require 'rails_helper'

RSpec.describe 'synthetic Azure measurement unit-price fixtures' do
  FIXTURE_PATHS = %w[
    ocr_azure_measurement_unit_price_positive_anonymized.json
    ocr_azure_measurement_unit_price_negative_anonymized.json
  ].freeze
  ALLOWED_ITEM_FIELDS = %w[Description Price Quantity QuantityUnit TotalPrice].freeze
  FORBIDDEN_PROVIDER_FIELDS = %w[
    MerchantName MerchantAddress MerchantPhoneNumber TransactionDate TransactionTime
    ReceiptId TransactionId LoyaltyCard Vehicle Payment Payments PaymentMethods
  ].freeze

  def fixture(name)
    JSON.parse(Rails.root.join('spec/fixtures/ocr', name).read)
  end

  def utf16_length(text)
    text.encode(Encoding::UTF_16LE).bytesize / 2
  end

  def utf16_slice(text, offset, length)
    encoded = text.encode(Encoding::UTF_16LE)
    encoded.byteslice(offset * 2, length * 2).to_s
      .force_encoding(Encoding::UTF_16LE)
      .encode(Encoding::UTF_8)
  end

  it 'is explicitly synthetic and contains only the approved Azure item shape' do
    fixtures = FIXTURE_PATHS.map { |path| fixture(path) }

    aggregate_failures do
      expect(fixtures.map { |data| data.fetch('model_id') }.uniq).to eq([ 'prebuilt-receipt' ])
      expect(fixtures.map { |data| data.fetch('api_version') }.uniq).to eq([ '2024-11-30' ])
      expect(fixtures).to all(include('synthetic' => true))
      expect(fixtures.sum { |data| data.fetch('cases').size }).to eq(14)
      expect(fixtures.first.fetch('cases').map { |item| item.fetch('classification') }).to eq(
        Array.new(4, 'reference_quantity_price')
      )
      expect(fixtures.last.fetch('cases').map { |item| item.fetch('classification') }.tally).to eq(
        'count_unit_price' => 6,
        'package_content' => 4
      )
    end

    fixtures.flat_map { |data| data.fetch('cases') }.each do |case_data|
      item = case_data.fetch('item')
      label = item.dig('valueObject', 'Description', 'valueString')

      aggregate_failures case_data.fetch('case_id') do
        expect(case_data.fetch('case_id')).to match(/\A[a-z0-9_]+\z/)
        expect(label).to start_with('SYNTH-')
        expect(item.fetch('valueObject').keys).to match_array(ALLOWED_ITEM_FIELDS)
        expect(item.keys).to match_array(%w[confidence content spans valueObject])
      end
    end

    serialized = fixtures.to_json
    FORBIDDEN_PROVIDER_FIELDS.each { |field| expect(serialized).not_to include(%Q("#{field}")) }
    expect(serialized).not_to match(%r{https?://|@[a-z0-9.-]+\.[a-z]{2,}}i)
  end

  it 'binds every child field to its own parent with exact UTF-16 offsets' do
    FIXTURE_PATHS.flat_map { |path| fixture(path).fetch('cases') }.each do |case_data|
      item = case_data.fetch('item')
      item_content = item.fetch('content')
      parent = item.fetch('spans').sole
      parent_start = parent.fetch('offset')
      parent_end = parent_start + parent.fetch('length')

      aggregate_failures case_data.fetch('case_id') do
        expect(parent_start).to eq(0)
        expect(parent.fetch('length')).to eq(utf16_length(item_content))

        item.fetch('valueObject').each_value do |field|
          span = field.fetch('spans').sole
          start_offset = span.fetch('offset')
          end_offset = start_offset + span.fetch('length')

          expect(start_offset).to be >= parent_start
          expect(end_offset).to be <= parent_end
          expect(utf16_slice(item_content, start_offset, span.fetch('length'))).to eq(field.fetch('content'))
        end
      end
    end
  end
end
