module Ai
  class ReceiptAnalysisSchema
    STORE_NAME_OPTIONS_KEYS = %w[schema_version checksum options relations invalid truncated].freeze
    STORE_NAME_OPTIONS_VERSIONS = %w[store_name_options_v1 store_name_options_v2].freeze
    STORE_OPTION_ID_PATTERN = /\Astore_option_[0-9a-f]{32}\z/
    STORE_RELATION_ID_PATTERN = /\Astore_relation_[0-9a-f]{32}\z/
    MAX_STORE_NAME_IDS = 100
    STORE_RELATION_OPTION_FIELDS = {
      "same_name" => :same_name_option_ids,
      "store_location" => :store_location_option_ids,
      "left_complete" => :left_complete_option_ids,
      "right_complete" => :right_complete_option_ids,
      "unrelated" => :separate_option_ids
    }.freeze
    STORE_RELATION_DECISIONS = (STORE_RELATION_OPTION_FIELDS.keys + [ "ambiguous" ]).freeze
    MAX_CONSTRAINED_SCHEMA_PROPERTIES = 5_000
    MAX_CONSTRAINED_SCHEMA_ENUM_VALUES = 1_000
    MAX_CONSTRAINED_SCHEMA_BYTES = 120_000

    class << self
      def to_json_schema(name_options: nil)
        schema = {
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
            "store" => store_schema(name_options),
            "purchase" => purchase_schema,
            "payment" => payment_schema,
            "items" => {
              "type" => "array",
              "items" => item_schema
            },
            "receipt_adjustments" => {
              "type" => "array",
              "items" => receipt_adjustment_schema
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
        constrain_store_name_selection(schema, name_options)
      end

      private

      def top_level_keys
        Ai::ResponseParser::REQUIRED_KEYS + [ "is_receipt_confidence" ]
      end

      def store_schema(name_options)
        object_schema(
          "store_name_selection" => store_name_selection_schema(name_options),
          "store_name" => nullable_string,
          "store_address" => nullable_string,
          "store_phone_number" => nullable_string
        )
      end

      def store_name_selection_schema(name_options)
        option_ids, relation_ids = store_name_identifiers(name_options)
        relations = relation_ids.to_h do |relation_id|
          [ relation_id, { "type" => "string", "enum" => STORE_RELATION_DECISIONS } ]
        end

        object_schema(
          "relations" => object_schema(relations),
          "decision" => { "type" => "string", "enum" => %w[select ambiguous reject] },
          "option_id" => nullable_string.merge("enum" => option_ids + [ nil ])
        ).merge("type" => [ "object", "null" ])
      end

      def constrain_store_name_selection(schema, name_options)
        return schema unless name_options.is_a?(Hash)
        return schema unless (name_options[:schema_version] || name_options["schema_version"]) == "store_name_options_v2"

        option_ids, relation_ids = store_name_identifiers(name_options)
        return schema if option_ids.empty? || relation_ids.empty?

        mappings = relation_option_mappings(name_options[:relations] || name_options["relations"], option_ids)
        return schema unless mappings

        groups = option_ids.group_by { |id| mappings.map { |mapping| relation_decisions(mapping, id) } }
        definitions = {}
        branches = groups.map do |choices, ids|
          constrained_selection_branch(relation_ids, choices, [ "select" ], ids, definitions)
        end
        branches << constrained_selection_branch(
          relation_ids, Array.new(relation_ids.size, STORE_RELATION_DECISIONS), %w[ambiguous reject], [ nil ], definitions
        )
        branches << { "type" => "null" }

        constrained = schema.deep_dup
        constrained.dig("properties", "store", "properties", "store_name_selection")["anyOf"] = branches
        constrained["$defs"] = definitions
        # 候補を削って上限を満たさず、既存のID制約と受信後の厳格な検証を維持する。
        constrained_schema_within_limits?(constrained) ? constrained : schema
      end

      def relation_option_mappings(entries, option_ids)
        keys = %w[relation_id candidate_ids] + STORE_RELATION_OPTION_FIELDS.values.map(&:to_s)
        entries.map do |entry|
          return unless entry.is_a?(Hash) && entry.size == keys.size
          return unless entry.keys.all? { |key| (key.is_a?(String) || key.is_a?(Symbol)) && keys.include?(key.to_s) }

          mapping = entry.symbolize_keys
          return unless mapping.size == entry.size
          return unless STORE_RELATION_OPTION_FIELDS.values.all? do |field|
            ids = mapping[field]
            ids.is_a?(Array) && ids.size <= MAX_STORE_NAME_IDS &&
              ids.all? { |id| id.is_a?(String) && id.bytesize <= 100 && option_ids.include?(id) } && ids.uniq.size == ids.size
          end

          combined = mapping[:same_name_option_ids] | mapping[:store_location_option_ids]
          separate = mapping[:separate_option_ids]
          left = mapping[:left_complete_option_ids]
          right = mapping[:right_complete_option_ids]
          return unless (combined & separate).empty? && (left - separate).empty? && (right - separate).empty? && (left & right).empty?

          mapping
        end
      end

      def relation_decisions(mapping, option_id)
        decisions = STORE_RELATION_OPTION_FIELDS.filter_map { |decision, field| decision if mapping[field].include?(option_id) }
        decisions.presence || STORE_RELATION_DECISIONS
      end

      def constrained_selection_branch(relation_ids, choices, decisions, option_ids, definitions)
        properties = relation_ids.zip(choices).to_h do |id, allowed|
          mask = allowed.sum { |decision| 1 << STORE_RELATION_DECISIONS.index(decision) }
          name = "store_name_relation_#{mask}"
          definitions[name] ||= { "type" => "string", "enum" => allowed }
          [ id, { "$ref" => "#/$defs/#{name}" } ]
        end
        object_schema(
          "relations" => object_schema(properties),
          "decision" => { "type" => "string", "enum" => decisions },
          "option_id" => nullable_string.merge("enum" => option_ids)
        )
      end

      def constrained_schema_within_limits?(schema)
        return false if JSON.generate(schema).bytesize > MAX_CONSTRAINED_SCHEMA_BYTES

        properties, enum_values = schema_size(schema)
        properties <= MAX_CONSTRAINED_SCHEMA_PROPERTIES && enum_values <= MAX_CONSTRAINED_SCHEMA_ENUM_VALUES
      end

      def schema_size(node)
        case node
        when Hash
          properties = node.fetch("properties", {}).size
          enum_values = node.fetch("enum", []).size
          node.each_value do |value|
            nested_properties, nested_enum_values = schema_size(value)
            properties += nested_properties
            enum_values += nested_enum_values
          end
          [ properties, enum_values ]
        when Array
          node.each_with_object([ 0, 0 ]) do |value, totals|
            properties, enum_values = schema_size(value)
            totals[0] += properties
            totals[1] += enum_values
          end
        else
          [ 0, 0 ]
        end
      end

      def store_name_identifiers(value)
        return [ [], [] ] unless value.is_a?(Hash) && value.size <= STORE_NAME_OPTIONS_KEYS.size
        return [ [], [] ] unless value.keys.all? { |key| (key.is_a?(String) || key.is_a?(Symbol)) && STORE_NAME_OPTIONS_KEYS.include?(key.to_s) }

        data = value.symbolize_keys
        return [ [], [] ] unless data.size == value.size && STORE_NAME_OPTIONS_VERSIONS.include?(data[:schema_version])
        return [ [], [] ] unless [ :invalid, :truncated ].all? { |key| !data.key?(key) || data[key] == false }

        option_ids = bounded_identifiers(data[:options], :option_id, STORE_OPTION_ID_PATTERN)
        relations = data[:schema_version] == "store_name_options_v1" ? data.fetch(:relations, []) : data[:relations]
        relation_ids = bounded_identifiers(relations, :relation_id, STORE_RELATION_ID_PATTERN)
        return [ [], [] ] unless option_ids && relation_ids
        return [ [], [] ] if data[:schema_version] == "store_name_options_v1" && relation_ids.any?
        return [ [], [] ] if option_ids.empty? && relation_ids.any?

        [ option_ids, relation_ids ]
      end

      def bounded_identifiers(entries, key, pattern)
        return unless entries.is_a?(Array) && entries.size <= MAX_STORE_NAME_IDS

        ids = entries.map do |entry|
          return unless entry.is_a?(Hash)
          return if entry.key?(key) && entry.key?(key.to_s)

          id = entry[key] || entry[key.to_s]
          return unless id.is_a?(String) && id.valid_encoding? && id.bytesize <= 100 && pattern.match?(id)

          id
        end
        ids if ids.uniq.size == ids.size
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

      def receipt_adjustment_schema
        object_schema(
          "kind" => {
            "type" => [ "string", "null" ],
            "enum" => ReceiptAdjustment::KINDS + [ nil ]
          },
          "label" => nullable_string,
          "amount" => nullable_integer(minimum: 0, maximum: ReceiptAmountService.receipt_adjustment_amount_max),
          "sign" => {
            "type" => [ "string", "null" ],
            "enum" => ReceiptAdjustment::SIGNS + [ nil ]
          },
          "tax_rate" => nullable_number(minimum: 0.0, maximum: 1.0),
          "source_text" => nullable_string,
          "source_line_index" => nullable_integer(minimum: 0),
          "confidence" => nullable_number(minimum: 0.0, maximum: 1.0),
          "needs_review" => nullable_boolean,
          "review_reasons" => {
            "type" => "array",
            "items" => {
              "type" => "string",
              "enum" => Ai::ResponseParser::ALLOWED_REVIEW_REASONS
            }
          }
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
