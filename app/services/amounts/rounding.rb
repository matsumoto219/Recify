# frozen_string_literal: true

module Amounts
  module Rounding
    module_function

    TAX_DEFAULT_MODE = :floor
    DISCOUNT_DEFAULT_MODE = :round

    def normalize_rounding_mode(value)
      mode = value.to_s.to_sym
      %i[floor ceil round].include?(mode) ? mode : :floor
    end

    def apply_rounding(value, rounding_mode)
      case normalize_rounding_mode(rounding_mode)
      when :ceil
        value.ceil
      when :round
        value.round(0, BigDecimal::ROUND_HALF_UP).to_i
      else
        value.floor
      end
    end
  end
end
