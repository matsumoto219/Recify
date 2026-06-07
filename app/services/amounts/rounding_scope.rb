# frozen_string_literal: true

module Amounts
  module RoundingScope
    SCOPES = %i[
      per_item
      per_tax_rate_group
      per_receipt
    ].freeze

    DEFAULT = :per_tax_rate_group

    module_function

    def normalize(value)
      scope = value.to_s.to_sym
      SCOPES.include?(scope) ? scope : DEFAULT
    end
  end
end
