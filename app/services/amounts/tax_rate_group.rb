# frozen_string_literal: true

module Amounts
  class TaxRateGroup
    attr_reader :rate, :gross, :net, :tax, :rounding_mode, :rounding_scope, :evidence

    def self.from_gross(rate:, gross:, rounding_mode:, rounding_scope: Amounts::RoundingScope::DEFAULT, evidence: [])
      new(
        rate: rate,
        gross: gross,
        net: nil,
        tax: nil,
        basis: :gross,
        rounding_mode: rounding_mode,
        rounding_scope: rounding_scope,
        evidence: evidence
      )
    end

    def self.from_net(rate:, net:, rounding_mode:, rounding_scope: Amounts::RoundingScope::DEFAULT, evidence: [])
      new(
        rate: rate,
        gross: nil,
        net: net,
        tax: nil,
        basis: :net,
        rounding_mode: rounding_mode,
        rounding_scope: rounding_scope,
        evidence: evidence
      )
    end

    def initialize(rate:, gross:, net:, tax:, basis:, rounding_mode:, rounding_scope:, evidence: [])
      @rate = normalize_rate(rate)
      @rounding_mode = Amounts::Rounding.normalize_rounding_mode(rounding_mode)
      @rounding_scope = Amounts::RoundingScope.normalize(rounding_scope)
      @evidence = Array(evidence)

      case basis.to_s.to_sym
      when :net
        @net = to_i(net)
        @tax = tax.nil? ? tax_from_net(@net, @rate) : to_i(tax)
        @gross = gross.nil? ? @net + @tax : to_i(gross)
      else
        @gross = to_i(gross)
        @tax = tax.nil? ? tax_from_gross(@gross, @rate) : to_i(tax)
        @net = net.nil? ? @gross - @tax : to_i(net)
      end
    end

    def to_h
      {
        rate: rate,
        gross: gross,
        net: net,
        tax: tax,
        rounding_mode: rounding_mode,
        rounding_scope: rounding_scope,
        evidence: evidence
      }.compact
    end

    def tax_detail
      {
        description: description,
        rate: rate,
        net_amount: net,
        amount: tax
      }
    end

    private

    def description
      percentage = rate * 100
      formatted = percentage.frac.zero? ? percentage.to_i.to_s : percentage.to_s("F")
      profile.tax_rate_target_label(formatted)
    end

    def profile
      ReceiptAnalysisProfiles.default
    end

    def tax_from_gross(gross_amount, tax_rate)
      return 0 unless tax_rate.positive?

      Amounts::Rounding.apply_rounding(
        BigDecimal(gross_amount.to_s) * tax_rate / (BigDecimal("1") + tax_rate),
        rounding_mode
      )
    end

    def tax_from_net(net_amount, tax_rate)
      return 0 unless tax_rate.positive?

      Amounts::Rounding.apply_rounding(BigDecimal(net_amount.to_s) * tax_rate, rounding_mode)
    end

    def normalize_rate(value)
      return BigDecimal("0") if value.nil? || value == ""

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      BigDecimal("0")
    end

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end
  end
end
