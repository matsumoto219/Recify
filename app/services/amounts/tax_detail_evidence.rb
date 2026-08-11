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

    def purchase_amount_evidence_present?
      return false if final_detected_tax_details.blank?

      # A valid group cannot determine the full purchase amount while another
      # value-bearing tax-detail row remains unresolved.
      final_indexes = final_detected_tax_details.map { |detail| detail[:index] }
      detected_tax_details.all? do |detail|
        source = tax_details[detail[:index]]
        next true unless source_has_amount_values?(source)

        case detail[:basis]
        when :gross, :net
          final_indexes.include?(detail[:index]) && complete_source?(source)
        when :intermediate
          complete_source?(source)
        when :summary
          true
        else
          false
        end
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

    def source_value(source, key)
      return source.public_send(key) if source.respond_to?(key)
      return source[key] if source.respond_to?(:key?) && source.key?(key)

      source[key.to_s] if source.respond_to?(:key?) && source.key?(key.to_s)
    end

    def value_present?(value)
      !value.nil? && value != ""
    end

    def source_has_amount_values?(source)
      source && %i[rate net_amount amount].any? { |key| value_present?(source_value(source, key)) }
    end

    def complete_source?(source)
      %i[rate net_amount amount].all? { |key| value_present?(source_value(source, key)) }
    end
  end
end
