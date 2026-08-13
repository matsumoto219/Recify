module Amounts::Limits
  DEFAULT_MAX = SystemSettings::AMOUNT_LIMIT_DEFAULT
  KEYS = {
    receipt_total_amount: "limits.receipt_total_amount_max",
    receipt_item_price: "limits.receipt_item_price_max",
    receipt_item_line_total: "limits.receipt_item_line_total_max",
    receipt_tax_amount: "limits.receipt_tax_amount_max",
    receipt_adjustment_amount: "limits.receipt_adjustment_amount_max",
    receipt_payment_amount: "limits.receipt_payment_amount_max"
  }.freeze
  FIELD_LIMITS = {
    receipt: {
      total_amount: :receipt_total_amount,
      subtotal_amount: :receipt_total_amount,
      tax_amount: :receipt_tax_amount,
      tip_amount: :receipt_adjustment_amount
    },
    receipt_items: {
      price: :receipt_item_price,
      line_total: :receipt_item_line_total,
      original_line_total: :receipt_item_line_total,
      discount_amount: :receipt_item_line_total
    },
    receipt_adjustments: {
      amount: :receipt_adjustment_amount
    },
    receipt_payments: {
      amount: :receipt_payment_amount
    },
    receipt_tax_details: {
      amount: :receipt_tax_amount,
      net_amount: :receipt_tax_amount
    }
  }.freeze

  class << self
    def receipt_total_amount_max
      limit_for(:receipt_total_amount)
    end

    def receipt_item_price_max
      limit_for(:receipt_item_price)
    end

    def receipt_item_line_total_max
      limit_for(:receipt_item_line_total)
    end

    def receipt_tax_amount_max
      limit_for(:receipt_tax_amount)
    end

    def receipt_adjustment_amount_max
      limit_for(:receipt_adjustment_amount)
    end

    def receipt_payment_amount_max
      limit_for(:receipt_payment_amount)
    end

    def limit_for(name)
      SystemSettings.limit_for(KEYS.fetch(name))
    rescue KeyError, SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      DEFAULT_MAX
    end

    def violations_for(receipt: {}, receipt_items: [], receipt_adjustments: [], receipt_payments: [], receipt_tax_details: [], source_only: false)
      limits = violation_limits

      [
        *record_violations(resource: :receipt, record: receipt, index: nil, source_only: source_only, limits: limits),
        *collection_violations(resource: :receipt_items, records: receipt_items, source_only: source_only, limits: limits),
        *collection_violations(resource: :receipt_adjustments, records: receipt_adjustments, source_only: source_only, limits: limits),
        *collection_violations(resource: :receipt_payments, records: receipt_payments, source_only: source_only, limits: limits),
        *collection_violations(resource: :receipt_tax_details, records: receipt_tax_details, source_only: source_only, limits: limits)
      ]
    end

    private

    def violation_limits
      stored_limits = SystemSettings.limits_for(KEYS.values)
      KEYS.to_h { |name, key| [ name, stored_limits.fetch(key) ] }
    rescue KeyError, SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      KEYS.keys.index_with { |name| limit_for(name) }
    end

    def collection_violations(resource:, records:, source_only:, limits:)
      Array(records).flat_map.with_index do |record, index|
        record_violations(resource: resource, record: record, index: index, source_only: source_only, limits: limits)
      end
    end

    def record_violations(resource:, record:, index:, source_only:, limits:)
      attributes = normalized_attributes(record)
      fields = fields_for(resource, attributes, source_only: source_only)

      fields.filter_map do |field, limit_name|
        actual_value = amount_value(attributes[field])
        next if actual_value.nil?

        limit = limits.fetch(limit_name)
        next if actual_value <= limit

        {
          resource: resource.to_s,
          field: field.to_s,
          limit: limit,
          actual_value: actual_value,
          index: index
        }.compact
      end
    end

    def fields_for(resource, attributes, source_only:)
      fields = FIELD_LIMITS.fetch(resource)
      return fields unless source_only && resource == :receipt_items

      case attributes[:pricing_source_kind].to_s
      when "reference_quantity_price"
        fields.except(:price, :line_total, :original_line_total)
      when "count_unit_price"
        fields.except(:line_total, :original_line_total)
      else
        fields
      end
    end

    def normalized_attributes(record)
      if record.respond_to?(:with_indifferent_access)
        record.with_indifferent_access
      elsif record.respond_to?(:attributes)
        record.attributes.with_indifferent_access
      elsif record.respond_to?(:to_h)
        record.to_h.with_indifferent_access
      else
        {}.with_indifferent_access
      end
    end

    def amount_value(value)
      Amounts::NumberParser.parse_amount_or_nil(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
