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

    def violations_for(receipt: {}, receipt_items: [], receipt_adjustments: [], receipt_payments: [], receipt_tax_details: [])
      [
        *record_violations(resource: :receipt, record: receipt, index: nil),
        *collection_violations(resource: :receipt_items, records: receipt_items),
        *collection_violations(resource: :receipt_adjustments, records: receipt_adjustments),
        *collection_violations(resource: :receipt_payments, records: receipt_payments),
        *collection_violations(resource: :receipt_tax_details, records: receipt_tax_details)
      ]
    end

    private

    def collection_violations(resource:, records:)
      Array(records).flat_map.with_index do |record, index|
        record_violations(resource: resource, record: record, index: index)
      end
    end

    def record_violations(resource:, record:, index:)
      fields = FIELD_LIMITS.fetch(resource)
      attributes = normalized_attributes(record)

      fields.filter_map do |field, limit_name|
        actual_value = amount_value(attributes[field])
        next if actual_value.nil?

        limit = limit_for(limit_name)
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
