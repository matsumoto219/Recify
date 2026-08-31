module Receipts::Processing::Contracts
  class ItemCalculationModeDecision
    CONTRACT_VERSION = "item_calculation_mode_decision_v1"
    PROPOSAL_CONTRACT = ItemCalculationModeProposalSet
    REASONS = %w[
      formula_matches_printed_total
      count_formula_only
      reference_formula_only
      explicit_total_only
      formula_total_mismatch
      count_tax_semantics_unknown
      reference_tax_semantics_unsupported
      source_out_of_bounds
      proposal_invalid
    ].freeze
    COUNT_TAX_SEMANTICS = %w[reproducible_as_recorded reproducible_uniform_net unknown].freeze
    EXACT_INTEGER_PATTERN = PROPOSAL_CONTRACT::EXACT_INTEGER_PATTERN

    Result = Data.define(
      :state,
      :reason,
      :candidate_id,
      :item_identity,
      :selected_proposal_id,
      :selected_pricing_source_kind,
      :projected_line_total,
      :option_proposal_ids,
      :contract_version
    ) do
      def initialize(
        state:,
        reason:,
        candidate_id: nil,
        item_identity: nil,
        selected_proposal_id: nil,
        selected_pricing_source_kind: nil,
        projected_line_total: nil,
        option_proposal_ids: []
      )
        super(
          state: state.to_s.dup.freeze,
          reason: reason.to_s.dup.freeze,
          candidate_id: candidate_id&.dup&.freeze,
          item_identity: item_identity&.dup&.freeze,
          selected_proposal_id: selected_proposal_id&.dup&.freeze,
          selected_pricing_source_kind: selected_pricing_source_kind&.dup&.freeze,
          projected_line_total: projected_line_total,
          option_proposal_ids: option_proposal_ids.map { |value| value.dup.freeze }.freeze,
          contract_version: CONTRACT_VERSION
        )
      end

      def confirmed?
        state == "confirmed"
      end

      def reviewable?
        state == "reviewable"
      end

      def unresolved?
        state == "unresolved"
      end
    end

    BatchResult = Data.define(:proposals, :decisions) do
      def initialize(proposals:, decisions:)
        super(proposals: proposals.freeze, decisions: decisions.freeze)
      end
    end

    class << self
      def call(
        item_identity:,
        item_proposals:,
        ocr_snapshot:,
        count_tax_semantics:,
        item_price_limit:,
        item_line_total_limit:
      )
        decisions = call_all(
          item_proposals:,
          ocr_snapshot:,
          count_tax_semantics:,
          item_price_limit:,
          item_line_total_limit:
        )
        return unresolved("proposal_invalid") unless decisions.is_a?(Array)

        matches = decisions.select { |decision| decision.item_identity == item_identity }
        matches.one? ? matches.sole : unresolved("proposal_invalid")
      end

      def call_all(
        item_proposals:,
        ocr_snapshot:,
        count_tax_semantics:,
        item_price_limit:,
        item_line_total_limit:
      )
        evaluate_all(
          item_proposals:,
          ocr_snapshot:,
          count_tax_semantics:,
          item_price_limit:,
          item_line_total_limit:
        )&.decisions
      end

      def evaluate_all(
        item_proposals:,
        ocr_snapshot:,
        count_tax_semantics:,
        item_price_limit:,
        item_line_total_limit:
      )
        proposals = PROPOSAL_CONTRACT.from_snapshot(item_proposals, ocr_snapshot:)
        return nil unless proposals.is_a?(Array)

        proposals = proposals.sort_by { |proposal| proposal.fetch("item_identity") }
        decisions = if !COUNT_TAX_SEMANTICS.include?(count_tax_semantics)
          proposals.map { |proposal| unresolved("proposal_invalid", proposal:) }
        elsif !valid_limit?(item_price_limit) || !valid_limit?(item_line_total_limit)
          proposals.map { |proposal| unresolved("source_out_of_bounds", proposal:) }
        else
          proposals.map do |proposal|
            decision_for(
              proposal,
              count_tax_semantics:,
              item_price_limit:,
              item_line_total_limit:
            )
          end
        end

        BatchResult.new(proposals:, decisions:)
      rescue EncodingError, ArgumentError, KeyError, TypeError
        nil
      end

      private

      def decision_for(proposal, count_tax_semantics:, item_price_limit:, item_line_total_limit:)
        if unsupported_reference_tax_semantics?(proposal)
          explicit = proposal.fetch("options").find do |option|
            option.fetch("pricing_source_kind") == "explicit_line_total"
          end
          projected_explicit = projected_explicit_option(explicit, item_line_total_limit:) if explicit
          return selected_result(
            proposal,
            projected_explicit,
            state: "reviewable",
            reason: "reference_tax_semantics_unsupported"
          ) if projected_explicit

          return unresolved("reference_tax_semantics_unsupported", proposal:)
        end

        projected = projected_options(
          proposal,
          item_price_limit:,
          item_line_total_limit:
        )
        if projected.nil?
          fallback = discounted_explicit_fallback(proposal, item_price_limit:, item_line_total_limit:)
          return selected_result(
            proposal,
            fallback,
            state: "reviewable",
            reason: "formula_total_mismatch"
          ) if fallback

          return unresolved("source_out_of_bounds", proposal:)
        end

        count = projected.find { |option| option.fetch(:kind) == "count_unit_price" }
        reference = projected.find { |option| option.fetch(:kind) == "reference_quantity_price" }
        explicit = projected.find { |option| option.fetch(:kind) == "explicit_line_total" }
        formula = count || reference
        return unresolved("proposal_invalid", proposal:) if count && reference

        if formula && explicit
          if formula.fetch(:amount) == explicit.fetch(:amount)
            return selected_formula_result(
              proposal,
              formula,
              count_tax_semantics:
            )
          end

          return selected_result(
            proposal,
            explicit,
            state: "reviewable",
            reason: "formula_total_mismatch"
          )
        end
        if explicit
          option = proposal.fetch("options").find { |entry| entry["pricing_source_kind"] == "explicit_line_total" }
          if option.key?("discount") && !explicit_discount_rate_matches?(option)
            return selected_result(
              proposal,
              explicit,
              state: "reviewable",
              reason: "formula_total_mismatch"
            )
          end

          return selected_result(proposal, explicit, state: "confirmed", reason: "explicit_total_only")
        end
        return selected_formula_result(
          proposal,
          formula,
          count_tax_semantics:,
          without_printed_total: true
        ) if formula

        unresolved("proposal_invalid", proposal:)
      rescue EncodingError, ArgumentError, KeyError, TypeError
        unresolved("proposal_invalid", proposal:)
      end

      def projected_options(proposal, item_price_limit:, item_line_total_limit:)
        proposal.fetch("options").sort_by { |option| option.fetch("proposal_id") }.map do |option|
          case option.fetch("pricing_source_kind")
          when "count_unit_price"
            projected_count_option(
              option,
              item_price_limit:,
              item_line_total_limit:
            )
          when "reference_quantity_price"
            projected_reference_option(option, item_line_total_limit:)
          when "explicit_line_total"
            projected_explicit_option(option, item_line_total_limit:)
          end
        end.then { |options| options if options.none?(&:nil?) }
      end

      def discounted_explicit_fallback(proposal, item_price_limit:, item_line_total_limit:)
        options = proposal.fetch("options")
        return unless options.map { |option| option["pricing_source_kind"] } == %w[count_unit_price explicit_line_total]

        count, explicit = options
        return unless count["discount"] == explicit["discount"] && explicit.dig("discount", "printed_total_stage") == "before_item_discount"

        before = projected_count_option(count.except("discount"), item_price_limit:, item_line_total_limit:)
        return unless before && before[:amount] == exact_integer(explicit.dig("source", "line_total_amount"))

        projected_explicit_option(explicit, item_line_total_limit:)
      end

      def explicit_discount_rate_matches?(option)
        ReceiptAmountService.item_discount_projection(
          original_line_total: option.dig("source", "line_total_amount"),
          discount_amount: option.dig("discount", "amount"),
          discount_rate: option.dig("discount", "rate")
        )
        true
      rescue ReceiptAmountService::InvalidItemSourceError
        false
      end

      def unsupported_reference_tax_semantics?(proposal)
        reference = proposal.fetch("options").find do |option|
          option.fetch("pricing_source_kind") == "reference_quantity_price"
        end
        reference && reference.dig("source", "reference_price_tax_inclusion") != "gross"
      end

      def projected_reference_option(option, item_line_total_limit:)
        source = option.fetch("source")
        return unless source.keys.sort == PROPOSAL_CONTRACT::REFERENCE_SOURCE_KEYS.sort
        return unless source["reference_price_tax_inclusion"] == "gross"

        projection = ReceiptAmountService.reference_item_extension_projection(
          reference_price_amount: source["reference_price_amount"],
          reference_quantity: source["reference_quantity"],
          reference_unit_code: source["reference_quantity_unit_code"],
          purchased_quantity: source["purchased_quantity"],
          purchased_unit_code: source["purchased_quantity_unit_code"]
        )
        amount = projection.fetch(:projected_amount)
        return unless amount.between?(0, item_line_total_limit)

        projected_option(option, amount)
      rescue ReceiptAmountService::InvalidItemSourceError
        nil
      end

      def projected_count_option(option, item_price_limit:, item_line_total_limit:)
        source = option.fetch("source")
        return unless source.keys.sort == PROPOSAL_CONTRACT::COUNT_SOURCE_KEYS.sort

        price = exact_integer(source["price_amount"])
        return unless price && price <= item_price_limit

        projection_arguments = {
          price_amount: source["price_amount"],
          purchased_quantity: source["quantity"],
          purchased_unit_code: source["quantity_unit_code"]
        }
        if option.key?("discount")
          projection_arguments[:discount_amount] = option.dig("discount", "amount")
          projection_arguments[:discount_rate] = option.dig("discount", "rate")
        end
        projection = ReceiptAmountService.count_item_extension_projection(**projection_arguments)
        amount = projection.fetch(:projected_amount)
        return unless amount.between?(0, item_line_total_limit)
        return unless projection.fetch(:original_line_total, amount).between?(0, item_line_total_limit)

        projected_option(option, amount)
      rescue ReceiptAmountService::InvalidItemSourceError
        nil
      end

      def projected_explicit_option(option, item_line_total_limit:)
        source = option.fetch("source")
        return unless source.keys.sort == PROPOSAL_CONTRACT::EXPLICIT_SOURCE_KEYS.sort

        amount = exact_integer(source["line_total_amount"])
        return unless amount&.between?(0, item_line_total_limit)
        if option.key?("discount")
          projection = ReceiptAmountService.item_discount_projection(
            original_line_total: source["line_total_amount"],
            discount_amount: option.dig("discount", "amount"),
            discount_rate: nil
          )
          amount = projection.fetch(:projected_amount)
        end

        projected_option(option, amount)
      rescue ReceiptAmountService::InvalidItemSourceError
        nil
      end

      def projected_option(option, amount)
        {
          id: option.fetch("proposal_id"),
          kind: option.fetch("pricing_source_kind"),
          amount: amount
        }.freeze
      end

      def selected_formula_result(proposal, formula, count_tax_semantics:, without_printed_total: false)
        if formula.fetch(:kind) == "reference_quantity_price"
          return selected_result(
            proposal,
            formula,
            state: "confirmed",
            reason: without_printed_total ? "reference_formula_only" : "formula_matches_printed_total"
          )
        end
        uniform_net = count_tax_semantics == "reproducible_uniform_net"
        if count_tax_semantics == "reproducible_as_recorded" || uniform_net
          return selected_result(
            proposal,
            formula,
            state: "confirmed",
            reason: without_printed_total ? "count_formula_only" : "formula_matches_printed_total"
          )
        end
        return unresolved("count_tax_semantics_unknown", proposal:) if without_printed_total

        selected_result(
          proposal,
          formula,
          state: "reviewable",
          reason: "count_tax_semantics_unknown"
        )
      end

      def selected_result(proposal, option, state:, reason:)
        Result.new(
          state:,
          reason:,
          candidate_id: proposal["candidate_id"],
          item_identity: proposal["item_identity"],
          selected_proposal_id: option.fetch(:id),
          selected_pricing_source_kind: option.fetch(:kind),
          projected_line_total: option.fetch(:amount),
          option_proposal_ids: proposal.fetch("options").map { |entry| entry.fetch("proposal_id") }.sort
        )
      end

      def unresolved(reason, proposal: nil)
        reason = REASONS.include?(reason) ? reason : "proposal_invalid"
        Result.new(
          state: "unresolved",
          reason:,
          candidate_id: proposal&.dig("candidate_id"),
          item_identity: proposal&.dig("item_identity"),
          option_proposal_ids: Array(proposal&.dig("options")).filter_map do |option|
            option["proposal_id"] if option.is_a?(Hash)
          end.sort
        )
      end

      def exact_integer(value)
        return unless value.is_a?(String) && value.bytesize <= PROPOSAL_CONTRACT::MAX_EXACT_NUMBER_BYTES
        return unless value.match?(EXACT_INTEGER_PATTERN)

        Integer(value, 10)
      rescue ArgumentError
        nil
      end

      def valid_limit?(value)
        value.is_a?(Integer) && value.between?(0, PROPOSAL_CONTRACT::MAX_AMOUNT.to_i)
      end
    end
  end
end
