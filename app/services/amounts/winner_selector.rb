# frozen_string_literal: true

module Amounts
  class WinnerSelector
    def initialize(candidates, context: :analysis, receipt: {})
      @candidates = Array(candidates)
      @context = context.to_s.to_sym
      @receipt = receipt || {}
    end

    def call
      accepted = candidates.reject(&:rejected?)
      pool = accepted.presence || candidates
      legacy = candidates.find { |candidate| candidate.source == :legacy }
      best = pool.min_by do |candidate|
        [
          candidate.score.to_i,
          source_priority(candidate),
          candidate.candidate_id
        ]
      end

      return best unless legacy&.accepted?
      # 手動/編集保存では既存入力を尊重し、accepted legacy が参照する補正済み line_total を再探索で揺らさない。
      return legacy unless context == :analysis
      return best if replacement_candidate?(best)

      legacy
    end

    private

    attr_reader :candidates, :context, :receipt

    def source_priority(candidate)
      candidate.source == :legacy ? 1 : 0
    end

    def replacement_candidate?(candidate)
      return false unless candidate
      return false if candidate.source == :legacy
      return false if candidate.rejected?

      mixed_tax_inclusion_candidate?(candidate) ||
        receipt_and_payment_reconciled_candidate?(candidate) ||
        external_tax_candidate?(candidate) ||
        payment_reconciled_candidate?(candidate) ||
        payment_adjusted_candidate?(candidate) ||
        purchase_adjusted_payment_candidate?(candidate)
    end

    def mixed_tax_inclusion_candidate?(candidate)
      candidate.basis == "mixed_by_tax_rate_group" &&
        candidate.warnings.include?(:price_tax_inclusion_uncertain) &&
        (candidate.payment_adjustment_total.to_i.nonzero? || !candidate.payment_amount_sum.nil?)
    end

    def external_tax_candidate?(candidate)
      return false unless candidate.basis == "external_tax_from_receipt"
      return false unless candidate.score.to_i <= legacy_score
      return false unless receipt_total_matches?(candidate)
      return false unless receipt_amounts_complete?(candidate)

      basis_values = candidate.evidence.filter_map do |entry|
        entry.respond_to?(:[]) ? entry[:basis] : nil
      end

      basis_values.present? && basis_values.all? { |basis| basis.to_sym == :net }
    end

    def receipt_total_matches?(candidate)
      total = receipt_amount(:total_amount)
      total.nil? || total == candidate.purchase_total.to_i
    end

    def receipt_and_payment_reconciled_candidate?(candidate)
      return false unless candidate.score.to_i < legacy_score
      return false unless receipt_total_matches?(candidate)

      !candidate.payment_amount_sum.nil? &&
        candidate.payment_amount_sum.to_i == candidate.final_payment_total.to_i
    end

    def receipt_amounts_complete?(_candidate)
      !receipt_amount(:subtotal_amount).nil? &&
        !receipt_amount(:tax_amount).nil? &&
        !receipt_amount(:total_amount).nil?
    end

    def receipt_amount(key)
      if receipt.respond_to?(:key?)
        value = receipt[key] || receipt[key.to_s]
      elsif receipt.respond_to?(key)
        value = receipt.public_send(key)
      end

      Amounts::NumberParser.parse_amount_or_nil(value)
    end

    def legacy_score
      @legacy_score ||= candidates.find { |candidate| candidate.source == :legacy }&.score.to_i
    end

    def payment_adjusted_candidate?(candidate)
      candidate.payment_adjustment_total.to_i.nonzero? &&
        candidate.payment_amount_sum.to_i == candidate.final_payment_total.to_i
    end

    def payment_reconciled_candidate?(candidate)
      !candidate.payment_amount_sum.nil? &&
        candidate.payment_amount_sum.to_i == candidate.final_payment_total.to_i &&
        candidate.tax_details.present? &&
        candidate.score.to_i < legacy_score
    end

    def purchase_adjusted_payment_candidate?(candidate)
      candidate.purchase_adjustment_total.to_i.nonzero? &&
        !candidate.payment_amount_sum.nil? &&
        candidate.payment_amount_sum.to_i == candidate.final_payment_total.to_i
    end
  end
end
