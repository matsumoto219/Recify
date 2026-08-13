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
      adjustment_schema = schema.dig('properties', 'receipt_adjustments', 'items')

      aggregate_failures do
        expect(schema.dig('properties', 'payment', 'properties', 'payment_method', 'enum')).to match_array(
          Receipt::PAYMENT_METHODS + [ nil ]
        )
        expect(item_schema.dig('properties', 'category', 'enum')).to eq(ReceiptItem::CATEGORIES + [ nil ])
        expect(schema.dig('properties', 'review_reasons', 'items', 'enum')).to match_array(
          Ai::ResponseParser::ALLOWED_REVIEW_REASONS
        )
        expect(adjustment_schema.dig('properties', 'review_reasons', 'items', 'enum')).to match_array(
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

    it '調整行金額maximumはdefaultの金額上限を使う' do
      expect(schema.dig('properties', 'receipt_adjustments', 'items', 'properties', 'amount', 'maximum')).to eq(999_999_999)
    end

    it '調整行金額maximumはSystemSettingsの金額上限に追従する' do
      create(:system_setting, key: 'limits.receipt_adjustment_amount_max', value: SystemSettings.stored_value(1_500))

      expect(schema.dig('properties', 'receipt_adjustments', 'items', 'properties', 'amount', 'maximum')).to eq(1_500)
    end

    it 'reference pricingのnumeric/source fieldsとcandidate選択をAI output schemaへ追加しない' do
      item_properties = schema.dig('properties', 'items', 'items', 'properties')
      prohibited_keys = %w[
        reference_pricing_candidate_id
        selected_reference_pricing_candidate_id
        candidate_id
        reference_price
        reference_price_amount
        reference_quantity
        purchased_quantity
        unit_raw
        reference_unit_code
        reference_unit_raw
        reference_price_tax_inclusion
        tax_inclusion_evidence
        pricing_source_kind
        printed_line_total
        source_text
        evidence
        corroboration
      ]

      aggregate_failures do
        expect(schema.fetch('properties')).not_to have_key('reference_pricing_candidates')
        expect(schema.fetch('properties')).not_to have_key('selected_reference_pricing_candidate_id')
        expect(schema.fetch('properties')).not_to have_key('selected_reference_pricing_candidate_ids')
        expect(item_properties.keys & prohibited_keys).to be_empty
        expect(schema.dig('properties', 'items', 'items', 'additionalProperties')).to be(false)
      end
    end
  end
end
