require 'rails_helper'

RSpec.describe Ocr::ResponseParser::StructuredSourceMetadataExtractor do
  subject(:extractor) do
    described_class.new(
      pages: pages,
      text_normalizer: lambda do |value|
        value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[[:space:]]+/, ' ').strip
      end
    )
  end

  let(:pages) do
    [
      {
        'lines' => [
          { 'content' => 'Coffee 180', 'spans' => [ { 'offset' => 0, 'length' => 10 } ] }
        ]
      }
    ]
  end

  def metadata(field, field_path: 'documents[0].fields.Items[0].TotalPrice')
    extractor.call(field: field, field_path: field_path)
  end

  it 'returns no metadata for a non-Hash field' do
    expect(metadata('180')).to eq({})
  end

  it 'keeps base metadata when no source line matches' do
    expect(metadata({ 'content' => '999' })).to eq(
      source_provider: 'azure_structured',
      source_field_path: 'documents[0].fields.Items[0].TotalPrice'
    )
  end

  it 'flattens pages and omits blank normalized lines from source indexes' do
    pages.replace(
      [
        { 'lines' => [ { 'content' => '  ' } ] },
        { 'lines' => [ { 'content' => 'Total 180' } ] }
      ]
    )

    expect(metadata({ 'content' => '180' })).to include(
      source_line_index: 0,
      source_span_start: 6,
      source_span_end: 9
    )
  end

  it 'uses provider span overlap before duplicate content fallback' do
    pages.replace(
      [
        {
          'lines' => [
            { 'content' => 'Item 180', 'spans' => [ { 'offset' => 0, 'length' => 8 } ] },
            { 'content' => 'Total 180', 'spans' => [ { 'offset' => 9, 'length' => 9 } ] }
          ]
        }
      ]
    )

    expect(metadata({ 'content' => '180', 'spans' => [ { 'offset' => 15, 'length' => 3 } ] })).to include(
      source_line_index: 1,
      source_span_start: 6,
      source_span_end: 9
    )
  end

  it 'falls back to normalized content when provider spans are absent' do
    expect(metadata({ 'content' => '１８０' })).to include(
      source_line_index: 0,
      source_span_start: 7,
      source_span_end: 10
    )
  end

  it 'prefers the normalized content position for the local span' do
    pages.first['lines'] = [
      { 'content' => 'X 180', 'spans' => [ { 'offset' => 100, 'length' => 5 } ] }
    ]

    expect(metadata({ 'content' => '180', 'spans' => [ { 'offset' => 101, 'length' => 3 } ] })).to include(
      source_span_start: 2,
      source_span_end: 5
    )
  end

  it 'clips provider-relative fallback spans to the normalized line' do
    pages.first['lines'] = [
      { 'content' => 'abc', 'spans' => [ { 'offset' => 10, 'length' => 3 } ] }
    ]

    expect(metadata({ 'content' => 'zzz', 'spans' => [ { 'offset' => 8, 'length' => 10 } ] })).to include(
      source_line_index: 0,
      source_span_start: 0,
      source_span_end: 3
    )
  end

  it 'ignores invalid provider offsets and lengths' do
    pages.first['lines'] = [
      { 'content' => 'Total 180', 'spans' => [ { 'offset' => 'invalid', 'length' => 9 } ] }
    ]

    expect(metadata({ 'content' => '180', 'spans' => [ { 'offset' => 6, 'length' => 0 } ] })).to include(
      source_line_index: 0,
      source_span_start: 6,
      source_span_end: 9
    )
  end
end
