module Ai
  class ReceiptAnalysisSchema
    class << self
      def to_json_schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "required" => top_level_keys,
          "properties" => {
            "is_receipt" => { "type" => "boolean" },
            "is_receipt_confidence" => nullable_number(minimum: 0.0, maximum: 1.0),
            "document_type" => nullable_string,
            "rejection_reason" => {
              "type" => [ "string", "null" ],
              "enum" => Ai::ResponseParser::ALLOWED_REJECTION_REASONS + [ nil ]
            },
            "store" => store_schema,
            "purchase" => purchase_schema,
            "payment" => payment_schema,
            "items" => {
              "type" => "array",
              "items" => item_schema
            },
            "needs_review" => { "type" => "boolean" },
            "review_reasons" => {
              "type" => "array",
              "items" => {
                "type" => "string",
                "enum" => Ai::ResponseParser::ALLOWED_REVIEW_REASONS
              }
            }
          }
        }
      end

      private

      def top_level_keys
        Ai::ResponseParser::REQUIRED_KEYS + [ "is_receipt_confidence" ]
      end

      def store_schema
        object_schema(
          "store_name" => nullable_string,
          "store_address" => nullable_string,
          "store_phone_number" => nullable_string
        )
      end

      def purchase_schema
        object_schema(
          "purchased_at_text" => nullable_string
        )
      end

      def payment_schema
        object_schema(
          "payment_method" => {
            "type" => [ "string", "null" ],
            "enum" => Receipt::PAYMENT_METHODS + [ nil ]
          }
        )
      end

      def item_schema
        object_schema(
          "index" => nullable_integer(minimum: 0),
          "suggested_name" => nullable_string,
          "category" => {
            "type" => [ "string", "null" ],
            "enum" => ReceiptItem::CATEGORIES + [ nil ]
          },
          "tax_rate" => nullable_number(minimum: 0.0, maximum: 1.0),
          "tax_rate_confidence" => nullable_number(minimum: 0.0, maximum: 1.0),
          "tax_rate_reason" => nullable_string,
          "needs_review" => nullable_boolean
        )
      end

      def object_schema(properties)
        {
          "type" => "object",
          "additionalProperties" => false,
          "required" => properties.keys,
          "properties" => properties
        }
      end

      def nullable_string
        { "type" => [ "string", "null" ] }
      end

      def nullable_boolean
        { "type" => [ "boolean", "null" ] }
      end

      def nullable_integer(minimum: nil, maximum: nil)
        schema = { "type" => [ "integer", "null" ] }
        schema["minimum"] = minimum unless minimum.nil?
        schema["maximum"] = maximum unless maximum.nil?
        schema
      end

      def nullable_number(minimum: nil, maximum: nil)
        schema = { "type" => [ "number", "null" ] }
        schema["minimum"] = minimum unless minimum.nil?
        schema["maximum"] = maximum unless maximum.nil?
        schema
      end
    end
  end
end
