# frozen_string_literal: true

module Amounts
  class TaxDetailBasisDetector
    BASIS_VALUES = %i[gross net tax_only summary intermediate unknown].freeze

    class << self
      def call(tax_details, rounding_modes: %i[floor round ceil])
        new(tax_details, rounding_modes: rounding_modes).call
      end
    end

    def initialize(tax_details, rounding_modes: %i[floor round ceil])
      @tax_details = Array(tax_details).map.with_index { |tax_detail, index| normalize_tax_detail(tax_detail, index) }
      @rounding_modes = Array(rounding_modes).map { |mode| Amounts::Rounding.normalize_rounding_mode(mode) }.uniq
    end

    def call
      tax_details.map do |tax_detail|
        basis = detect_basis(tax_detail)
        tax_amount = tax_detail[:amount].to_i
        net_amount = tax_detail[:net_amount].to_i

        {
          index: tax_detail[:index],
          basis: basis,
          rate: tax_detail[:rate],
          printed_amount: net_amount,
          printed_amount_basis: printed_amount_basis(basis),
          net_amount: net_amount,
          amount: tax_amount,
          target_net_amount: target_net_amount(basis, net_amount, tax_amount),
          target_tax_amount: tax_amount,
          target_gross_amount: target_gross_amount(basis, net_amount, tax_amount),
          description: tax_detail[:description],
          intermediate: basis == :intermediate,
          evidence: evidence_for(tax_detail, basis)
        }
      end
    end

    private

    attr_reader :tax_details, :rounding_modes

    def detect_basis(tax_detail)
      description = tax_detail[:description].to_s
      rate = tax_detail[:rate]
      net_amount = tax_detail[:net_amount].to_i
      tax_amount = tax_detail[:amount].to_i

      return :summary if summary_detail?(tax_detail)
      return :intermediate if intermediate_detail?(tax_detail)
      return :tax_only if net_amount <= 0 && tax_amount.positive?
      return :unknown unless rate.positive? && net_amount.positive?
      return zero_tax_basis(description, net_amount, rate) if tax_amount.zero?
      return :unknown unless tax_amount.positive?
      return :net if description.match?(profile.amount_tax_detail_net_pattern)

      gross_match = tax_from_gross_matches?(net_amount, rate, tax_amount)
      net_match = tax_from_net_matches?(net_amount, rate, tax_amount)

      return :gross if gross_match && description.match?(profile.amount_tax_detail_gross_pattern)
      return :net if net_match && !gross_match
      return :gross if gross_match && !net_match
      return :net if net_match

      :unknown
    end

    def zero_tax_basis(description, printed_amount, rate)
      net_match = tax_from_net_matches?(printed_amount, rate, 0)
      gross_match = tax_from_gross_matches?(printed_amount, rate, 0)

      return :net if net_match && description.match?(profile.amount_tax_detail_net_pattern)
      return :net if net_match && description.match?(profile.amount_tax_detail_intermediate_pattern)
      return :gross if gross_match && description.match?(profile.amount_tax_detail_gross_pattern)

      return :net if net_match && !gross_match
      return :gross if gross_match && !net_match

      :unknown
    end

    def summary_detail?(tax_detail)
      tax_detail[:rate].zero? &&
        tax_detail[:net_amount].to_i.zero? &&
        tax_detail[:amount].to_i.positive? &&
        tax_detail[:description].to_s.match?(profile.amount_tax_detail_tax_only_pattern)
    end

    def intermediate_detail?(tax_detail)
      return true if tax_detail[:description].to_s.match?(profile.amount_tax_detail_intermediate_pattern) && same_rate_final_detail_exists?(tax_detail)

      inferred_intermediate_detail?(tax_detail)
    end

    def same_rate_final_detail_exists?(tax_detail)
      tax_details.any? do |other|
        next false if other[:index] == tax_detail[:index]

        other[:rate] == tax_detail[:rate] &&
          other[:net_amount].to_i.positive? &&
          other[:amount].to_i.positive? &&
          !other[:description].to_s.match?(profile.amount_tax_detail_intermediate_pattern)
      end
    end

    def inferred_intermediate_detail?(tax_detail)
      rate = tax_detail[:rate]
      net_amount = tax_detail[:net_amount].to_i
      tax_amount = tax_detail[:amount].to_i
      return false unless rate.positive? && net_amount.positive? && tax_amount.positive?
      return false unless tax_from_net_matches?(net_amount, rate, tax_amount)

      same_rate_containing_gross_detail_exists?(tax_detail)
    end

    def same_rate_containing_gross_detail_exists?(tax_detail)
      current_gross = tax_detail[:net_amount].to_i + tax_detail[:amount].to_i

      tax_details.any? do |other|
        next false if other[:index] == tax_detail[:index]
        next false unless other[:rate] == tax_detail[:rate]
        next false unless other[:net_amount].to_i.positive? && other[:amount].to_i.positive?
        next false unless tax_from_gross_matches?(other[:net_amount].to_i, other[:rate], other[:amount].to_i)

        other[:net_amount].to_i > current_gross && other[:amount].to_i >= tax_detail[:amount].to_i
      end
    end

    def target_net_amount(basis, net_amount, tax_amount)
      case basis
      when :gross
        [ net_amount - tax_amount, 0 ].max
      when :net
        net_amount
      else
        net_amount
      end
    end

    def target_gross_amount(basis, net_amount, tax_amount)
      case basis
      when :gross
        net_amount
      when :net
        net_amount + tax_amount
      else
        net_amount
      end
    end

    def printed_amount_basis(basis)
      case basis
      when :gross
        :gross_target
      when :net
        :net_subtotal
      when :tax_only
        :tax_only
      when :intermediate
        :intermediate
      when :summary
        :summary
      else
        :unknown
      end
    end

    def evidence_for(tax_detail, basis)
      tax_amount = tax_detail[:amount].to_i
      printed_amount = tax_detail[:net_amount].to_i

      {
        source: "receipt_tax_detail",
        index: tax_detail[:index],
        basis: basis,
        rate: tax_detail[:rate],
        printed_amount: tax_detail[:net_amount],
        printed_amount_basis: printed_amount_basis(basis),
        net_amount: tax_detail[:net_amount],
        amount: tax_detail[:amount],
        target_net_amount: target_net_amount(basis, printed_amount, tax_amount),
        target_tax_amount: tax_detail[:amount],
        target_gross_amount: target_gross_amount(basis, printed_amount, tax_amount)
      }
    end

    def tax_from_gross_matches?(gross_amount, rate, tax_amount)
      rounding_modes.any? do |rounding_mode|
        Amounts::Rounding.apply_rounding(BigDecimal(gross_amount.to_s) * rate / (BigDecimal("1") + rate), rounding_mode) == tax_amount
      end
    end

    def tax_from_net_matches?(net_amount, rate, tax_amount)
      rounding_modes.any? do |rounding_mode|
        Amounts::Rounding.apply_rounding(BigDecimal(net_amount.to_s) * rate, rounding_mode) == tax_amount
      end
    end

    def normalize_tax_detail(value, index)
      normalized =
        if value.respond_to?(:attributes)
          value.attributes.symbolize_keys
        elsif value.respond_to?(:to_h)
          value.to_h.symbolize_keys
        else
          {}
        end

      {
        index: index,
        amount: Amounts::NumberParser.parse_amount(normalized[:amount]),
        rate: normalize_rate(normalized[:rate]),
        net_amount: Amounts::NumberParser.parse_amount(normalized[:net_amount]),
        description: normalized[:description]
      }
    end

    def normalize_rate(value)
      return BigDecimal("0") if value.nil? || value == ""

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      BigDecimal("0")
    end

    def profile
      ReceiptAnalysisProfiles.default
    end
  end
end
