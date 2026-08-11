# frozen_string_literal: true

module Amounts
  class ItemPricingSource
    class InvalidContractError < ArgumentError; end

    SourceRule = Data.define(:authority_kind, :validation_states)

    AUTHORITY_KINDS = %i[
      count_unit_price
      explicit_line_total
      reference_quantity_price
    ].freeze
    VALIDATION_STATES = %i[valid missing ambiguous unsupported].freeze
    SOURCE_RULES = {
      analysis: {
        strongly_attributed_printed_total: SourceRule.new(
          authority_kind: :explicit_line_total,
          validation_states: %i[valid ambiguous unsupported].freeze
        ),
        existing_countable_formula: SourceRule.new(
          authority_kind: :count_unit_price,
          validation_states: %i[valid].freeze
        ),
        ambiguous_pricing_evidence: SourceRule.new(
          authority_kind: nil,
          validation_states: %i[ambiguous].freeze
        ),
        unsupported_pricing_evidence: SourceRule.new(
          authority_kind: nil,
          validation_states: %i[unsupported].freeze
        )
      }.freeze,
      manual: {
        entered_explicit_total: SourceRule.new(
          authority_kind: :explicit_line_total,
          validation_states: %i[valid ambiguous unsupported].freeze
        ),
        existing_countable_formula: SourceRule.new(
          authority_kind: :count_unit_price,
          validation_states: %i[valid].freeze
        ),
        confirmed_reference_quantity_price: SourceRule.new(
          authority_kind: :reference_quantity_price,
          validation_states: %i[valid].freeze
        )
      }.freeze,
      edit_save: {
        entered_explicit_total: SourceRule.new(
          authority_kind: :explicit_line_total,
          validation_states: %i[valid ambiguous unsupported].freeze
        ),
        existing_countable_formula: SourceRule.new(
          authority_kind: :count_unit_price,
          validation_states: %i[valid].freeze
        ),
        confirmed_reference_quantity_price: SourceRule.new(
          authority_kind: :reference_quantity_price,
          validation_states: %i[valid].freeze
        )
      }.freeze,
      persisted_without_source_metadata: {
        existing_countable_formula: SourceRule.new(
          authority_kind: :count_unit_price,
          validation_states: %i[valid].freeze
        ),
        persisted_measurement_explicit_total: SourceRule.new(
          authority_kind: :explicit_line_total,
          validation_states: %i[valid].freeze
        ),
        persisted_measurement_missing_total: SourceRule.new(
          authority_kind: nil,
          validation_states: %i[missing].freeze
        )
      }.freeze
    }.freeze
    CONTRACT_SYMBOLS = (
      AUTHORITY_KINDS +
      VALIDATION_STATES +
      SOURCE_RULES.keys +
      SOURCE_RULES.values.flat_map(&:keys)
    ).uniq.freeze
    CONTRACT_SYMBOL_BY_STRING = CONTRACT_SYMBOLS.to_h { |value| [ value.to_s.freeze, value ] }.freeze

    attr_reader :authority_kind,
      :context,
      :source_evidence,
      :validation_state,
      :explicit_line_total,
      :quantity_semantics

    class << self
      def analysis_printed(explicit_line_total:, validation_state: :valid)
        new(
          authority_kind: :explicit_line_total,
          context: :analysis,
          source_evidence: :strongly_attributed_printed_total,
          validation_state: validation_state,
          explicit_line_total: explicit_line_total
        )
      end

      def analysis_ambiguous(quantity_semantics: nil)
        new(
          authority_kind: nil,
          context: :analysis,
          source_evidence: :ambiguous_pricing_evidence,
          validation_state: :ambiguous,
          quantity_semantics: quantity_semantics
        )
      end

      def analysis_unsupported(quantity_semantics: nil)
        new(
          authority_kind: nil,
          context: :analysis,
          source_evidence: :unsupported_pricing_evidence,
          validation_state: :unsupported,
          quantity_semantics: quantity_semantics
        )
      end

      def manual_explicit(explicit_line_total:, validation_state: :valid)
        new(
          authority_kind: :explicit_line_total,
          context: :manual,
          source_evidence: :entered_explicit_total,
          validation_state: validation_state,
          explicit_line_total: explicit_line_total
        )
      end

      def existing_countable(context:, quantity_semantics:)
        new(
          authority_kind: :count_unit_price,
          context: context,
          source_evidence: :existing_countable_formula,
          quantity_semantics: quantity_semantics
        )
      end

      def manual_reference(quantity_semantics:)
        new(
          authority_kind: :reference_quantity_price,
          context: :manual,
          source_evidence: :confirmed_reference_quantity_price,
          quantity_semantics: quantity_semantics
        )
      end

      def edit_save_explicit(explicit_line_total:, validation_state: :valid)
        new(
          authority_kind: :explicit_line_total,
          context: :edit_save,
          source_evidence: :entered_explicit_total,
          validation_state: validation_state,
          explicit_line_total: explicit_line_total
        )
      end

      def edit_save_reference(quantity_semantics:)
        new(
          authority_kind: :reference_quantity_price,
          context: :edit_save,
          source_evidence: :confirmed_reference_quantity_price,
          quantity_semantics: quantity_semantics
        )
      end

      def measurement_without_source_metadata(explicit_line_total:)
        if explicit_line_total.nil?
          return new(
            authority_kind: nil,
            context: :persisted_without_source_metadata,
            source_evidence: :persisted_measurement_missing_total,
            validation_state: :missing
          )
        end

        new(
          authority_kind: :explicit_line_total,
          context: :persisted_without_source_metadata,
          source_evidence: :persisted_measurement_explicit_total,
          explicit_line_total: explicit_line_total
        )
      end
    end

    def initialize(
      authority_kind:,
      context:,
      source_evidence:,
      validation_state: :valid,
      explicit_line_total: nil,
      quantity_semantics: nil
    )
      @authority_kind = normalize_optional_symbol(authority_kind)
      @context = normalize_symbol(context)
      @source_evidence = normalize_symbol(source_evidence)
      @validation_state = normalize_symbol(validation_state)
      @explicit_line_total = explicit_line_total
      @quantity_semantics = quantity_semantics

      validate_contract!
      freeze
    end

    def authoritative?
      !authority_kind.nil?
    end

    def explicit?
      authority_kind == :explicit_line_total
    end

    def formula?
      %i[count_unit_price reference_quantity_price].include?(authority_kind)
    end

    private

    def validate_contract!
      validate_authority_kind!
      validate_state!
      validate_source_rule!
      validate_authority_value!
      validate_formula_source!
    end

    def validate_authority_kind!
      return if authority_kind.nil? || AUTHORITY_KINDS.include?(authority_kind)

      raise InvalidContractError, "unknown item pricing authority kind"
    end

    def validate_state!
      unless VALIDATION_STATES.include?(validation_state)
        raise InvalidContractError, "unknown item pricing validation state"
      end
    end

    def validate_source_rule!
      context_rules = SOURCE_RULES[context]
      unless context_rules&.key?(source_evidence)
        raise InvalidContractError, "unknown item pricing context or source evidence"
      end

      rule = context_rules.fetch(source_evidence)
      return if rule.authority_kind == authority_kind && rule.validation_states.include?(validation_state)

      raise InvalidContractError, "item pricing authority or state does not match its explicit source evidence"
    end

    def validate_authority_value!
      if explicit?
        unless explicit_line_total.is_a?(Integer) && explicit_line_total >= 0
          raise InvalidContractError, "explicit line total authority requires non-negative integer yen"
        end
      elsif !explicit_line_total.nil?
        raise InvalidContractError, "formula authority cannot use an explicit or hidden line total as source"
      end

      validate_nonformula_quantity_semantics! unless formula?
    end

    def validate_formula_source!
      return unless formula?

      unless quantity_semantics.is_a?(Amounts::ItemQuantitySemantics)
        raise InvalidContractError, "formula authority requires item quantity semantics"
      end

      if authority_kind == :count_unit_price
        quantity_semantics.validate_count_formula!
      else
        quantity_semantics.validate_reference_formula!
      end
    end

    def validate_nonformula_quantity_semantics!
      return if quantity_semantics.nil?

      review_state = %i[ambiguous unsupported].include?(validation_state)
      immutable_semantics = quantity_semantics.is_a?(Amounts::ItemQuantitySemantics) && quantity_semantics.frozen?
      return if authority_kind.nil? && review_state && immutable_semantics

      raise InvalidContractError, "only authority-free review state can retain immutable quantity semantics"
    end

    def normalize_optional_symbol(value)
      value.nil? ? nil : normalize_symbol(value)
    end

    def normalize_symbol(value)
      return value if value.is_a?(Symbol)
      return CONTRACT_SYMBOL_BY_STRING[value] if value.is_a?(String) && CONTRACT_SYMBOL_BY_STRING.key?(value)

      raise InvalidContractError, "item pricing contract values must be symbols or strings"
    end
  end
end
