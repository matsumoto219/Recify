# frozen_string_literal: true

module Amounts
  class TaxDetailEvidence
    def initialize(tax_details)
      @tax_details = Array(tax_details)
    end

    def detected_tax_details
      @detected_tax_details ||= Amounts::TaxDetailBasisDetector.call(tax_details)
    end

    def final_detected_tax_details
      @final_detected_tax_details ||= detected_tax_details.select do |detail|
        %i[gross net].include?(detail[:basis]) &&
          detail[:rate].positive? &&
          detail[:net_amount].to_i.positive? &&
          detail[:amount].to_i >= 0 &&
          detail[:target_gross_amount].to_i.positive?
      end
    end

    def incomplete_source_tax_details
      @incomplete_source_tax_details ||= detected_tax_details.filter_map do |detail|
        next unless detail[:amount].to_i.positive?
        next if detail[:rate].positive? && detail[:net_amount].to_i.positive?

        {
          description: detail[:description],
          rate: nil,
          net_amount: nil,
          amount: detail[:amount]
        }
      end
    end

    def targets_by_rate
      final_detected_tax_details.each_with_object({}) do |detail, hash|
        rate = detail[:rate]
        next unless rate.positive?

        hash[rate] ||= { rate: rate, gross: 0, net: 0, tax: 0 }
        hash[rate][:gross] += detail[:target_gross_amount].to_i
        hash[rate][:net] += detail[:target_net_amount].to_i
        hash[rate][:tax] += detail[:target_tax_amount].to_i
      end
    end

    private

    attr_reader :tax_details
  end
end
