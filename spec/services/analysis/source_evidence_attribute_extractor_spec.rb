require 'rails_helper'

RSpec.describe Analysis::SourceEvidenceAttributeExtractor do
  describe '.call' do
    it 'returns only non-nil source evidence attributes with symbol keys' do
      value = {
        'source_provider' => 'azure',
        source_field_path: 'Items[0]',
        'source_line_index' => 0,
        source_span_start: 0,
        'source_span_end' => nil,
        raw_response: 'secret',
        api_key: 'secret'
      }

      expect(described_class.call(value)).to eq(
        source_provider: 'azure',
        source_field_path: 'Items[0]',
        source_line_index: 0,
        source_span_start: 0
      )
    end

    it 'preserves false and blank values while removing only nil' do
      expect(
        described_class.call(
          source_provider: '',
          source_field_path: false,
          source_line_index: nil
        )
      ).to eq(source_provider: '', source_field_path: false)
    end

    it 'accepts objects that expose to_h' do
      value = Struct.new(:source_provider, :source_line_index, keyword_init: true).new(
        source_provider: 'fixture',
        source_line_index: 3
      )

      expect(described_class.call(value)).to eq(source_provider: 'fixture', source_line_index: 3)
    end

    it 'returns an empty hash for values without to_h' do
      aggregate_failures do
        expect(described_class.call(nil)).to eq({})
        expect(described_class.call(Object.new)).to eq({})
      end
    end

    it 'does not mutate the input hash' do
      value = { source_provider: 'azure', raw_response: 'raw' }
      original = value.deep_dup

      described_class.call(value)

      expect(value).to eq(original)
    end
  end
end
