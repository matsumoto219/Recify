require 'rails_helper'

RSpec.describe Ai::ReceiptAnalysisSchema do
  describe '.to_json_schema' do
    subject(:schema) { described_class.to_json_schema }

    def object_schemas(node)
      case node
      when Hash
        nested = node.values.flat_map { |value| object_schemas(value) }
        node['type'] == 'object' ? [ node ] + nested : nested
      when Array
        node.flat_map { |value| object_schemas(value) }
      else
        []
      end
    end

    it 'root objectとtop-level required keysを定義する' do
      aggregate_failures do
        expect(schema['type']).to eq('object')
        expect(schema['required']).to include(*Ai::ResponseParser::REQUIRED_KEYS)
        expect(schema['required']).to include('is_receipt_confidence')
        expect(schema['required']).to match_array(schema['properties'].keys)
      end
    end

    it 'classification keysを定義する' do
      aggregate_failures do
        expect(schema.dig('properties', 'is_receipt', 'type')).to eq('boolean')
        expect(schema.dig('properties', 'is_receipt_confidence', 'type')).to eq([ 'number', 'null' ])
        expect(schema.dig('properties', 'document_type', 'type')).to eq([ 'string', 'null' ])
        expect(schema.dig('properties', 'rejection_reason', 'enum')).to match_array(
          Ai::ResponseParser::ALLOWED_REJECTION_REASONS + [ nil ]
        )
      end
    end

    it 'rejection_reason enumがResponseParserと整合する' do
      expect(schema.dig('properties', 'rejection_reason', 'enum').compact).to match_array(
        Ai::ResponseParser::ALLOWED_REJECTION_REASONS
      )
    end

    it 'payment_method / item category / review_reasons のenumを定義する' do
      item_schema = schema.dig('properties', 'items', 'items')

      aggregate_failures do
        expect(schema.dig('properties', 'payment', 'properties', 'payment_method', 'enum')).to match_array(
          Receipt::PAYMENT_METHODS + [ nil ]
        )
        expect(item_schema.dig('properties', 'category', 'enum')).to match_array(ReceiptItem::CATEGORIES + [ nil ])
        expect(schema.dig('properties', 'review_reasons', 'items', 'enum')).to match_array(
          Ai::ResponseParser::ALLOWED_REVIEW_REASONS
        )
      end
    end

    it 'object schemaは additionalProperties false にする' do
      expect(object_schemas(schema)).to all(include('additionalProperties' => false))
    end

    it 'nullable表現を含む' do
      aggregate_failures do
        expect(schema.dig('properties', 'store', 'properties', 'store_name', 'type')).to eq([ 'string', 'null' ])
        expect(schema.dig('properties', 'items', 'items', 'properties', 'tax_rate', 'type')).to eq([ 'number', 'null' ])
      end
    end
  end
end
