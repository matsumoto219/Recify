# frozen_string_literal: true

module Analysis
  class TaxDetailLineEvidenceExtractor
    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(lines:, receipt_total:, receipt_tax:, existing_tax_details: [], profile: ReceiptAnalysisProfiles.default)
      @lines = Array(lines)
      @receipt_total = amount_or_nil(receipt_total)&.to_i
      @receipt_tax = amount_or_nil(receipt_tax)&.to_i
      @existing_tax_details = Array(existing_tax_details)
      @profile = profile
    end

    def call
      return [] unless receipt_total&.positive?
      return [] if receipt_tax.nil? || receipt_tax.negative?

      details = deduplicate_details(extracted_details)
      return [] if details.blank?
      return [] if details.one? && !single_rate_target_recovery_allowed?
      return [] unless details.sum { |detail| detail[:net_amount].to_i + detail[:amount].to_i } == receipt_total
      return [] unless details.sum { |detail| detail[:amount].to_i } == receipt_tax

      details
    end

    private

    attr_reader :lines, :receipt_total, :receipt_tax, :existing_tax_details, :profile

    def extracted_details
      lines.each_with_index.filter_map do |line, index|
        basis = target_basis_from_line(line)
        next if basis.blank?

        rate = rate_from_line(line)
        next if rate.blank?

        amount = amount_near_line(index)
        next unless amount&.positive?

        detail_for(rate:, amount:, basis:, line:)
      end
    end

    def detail_for(rate:, amount:, basis:, line:)
      tax =
        case basis
        when :net
          tax_from_net(amount, rate)
        when :gross
          tax_from_gross(amount, rate)
        end
      return if tax.nil? || tax.negative?

      {
        description: description_for(line, rate, basis),
        rate: rate,
        net_amount: basis == :gross ? amount - tax : amount,
        amount: tax
      }
    end

    def target_basis_from_line(line)
      text = normalize_text(line)
      return nil if text.blank?
      return nil if text.match?(profile.analysis_tax_amount_description_pattern)
      return :net if text.match?(profile.amount_tax_detail_net_pattern)
      return :net if text.match?(profile.amount_tax_detail_intermediate_pattern)
      return :gross if text.match?(profile.analysis_tax_target_marker_pattern)
      return :gross if text.match?(profile.amount_tax_detail_gross_pattern)

      nil
    end

    def rate_from_line(line)
      match = normalize_text(line).match(/(\d+(?:\.\d+)?)\s*[%％]/)
      normalize_rate(match[1]) if match
    end

    def amount_near_line(index)
      lines_window_until_next_tax_target(index).filter_map do |line|
        amount_from_line(line)
      end.find(&:positive?)
    end

    def amount_from_line(line)
      text = normalize_text(line).gsub(/\d+(?:\.\d+)?\s*[%％]/, " ")
      amounts = text.to_enum(:scan, /[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:円)?/).filter_map do |match|
        amount_or_nil(match)&.to_i
      end

      amounts.select(&:positive?).max
    end

    def lines_window_until_next_tax_target(index)
      lines[index, 4].to_a.take_while.with_index do |line, offset|
        offset.zero? || target_basis_from_line(line).blank?
      end
    end

    def deduplicate_details(details)
      Array(details).group_by { |detail| detail_key(detail) }.values.filter_map do |group|
        group.find { |detail| net_basis_description?(detail[:description]) } || group.first
      end
    end

    def detail_key(detail)
      [
        detail[:rate].to_s("F"),
        detail[:net_amount].to_i,
        detail[:amount].to_i,
        detail[:net_amount].to_i + detail[:amount].to_i
      ]
    end

    def description_for(line, rate, basis)
      return normalize_text(line).strip if basis == :net

      profile.tax_rate_target_label(rate_percentage_label(rate))
    end

    def net_basis_description?(description)
      text = normalize_text(description)
      text.match?(profile.amount_tax_detail_net_pattern) || text.match?(profile.amount_tax_detail_intermediate_pattern)
    end

    def single_rate_target_recovery_allowed?
      existing_tax_details.none? do |tax_detail|
        normalize_rate(tax_detail_value(tax_detail, :rate))&.positive?
      end
    end

    def tax_detail_value(tax_detail, key)
      return tax_detail[key] if tax_detail.respond_to?(:key?) && tax_detail.key?(key)
      return tax_detail[key.to_s] if tax_detail.respond_to?(:key?) && tax_detail.key?(key.to_s)

      nil
    end

    def tax_from_gross(gross_amount, rate)
      ReceiptAmountService.apply_rounding(BigDecimal(gross_amount.to_s) * rate / (BigDecimal("1") + rate), :floor)
    end

    def tax_from_net(net_amount, rate)
      ReceiptAmountService.apply_rounding(BigDecimal(net_amount.to_s) * rate, :floor)
    end

    def amount_or_nil(value)
      ReceiptAmountService.parse_amount_or_nil(value)
    end

    def normalize_rate(value)
      return if value.blank?

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      nil
    end

    def rate_percentage_label(rate)
      value = rate * 100
      value.frac.zero? ? value.to_i.to_s : value.to_s("F")
    end

    def normalize_text(value)
      value.to_s.unicode_normalize(:nfkc)
    end
  end
end
