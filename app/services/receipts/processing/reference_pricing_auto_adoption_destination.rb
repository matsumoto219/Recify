class Receipts::Processing::ReferencePricingAutoAdoptionDestination
  ITEM_COUNT_KEYS = %w[actual_count snapshot_count].freeze
  MAX_TOP_LEVEL_ENTRIES = 24
  MAX_NESTED_ENTRIES = 32
  MAX_PROPOSAL_CONTAINER_ENTRIES = 8

  Result = Data.define(:candidate_identity, :destination_identity, :item_attributes) do
    def initialize(candidate_identity:, destination_identity:, item_attributes:)
      super(
        candidate_identity: candidate_identity.dup.freeze,
        destination_identity: destination_identity.dup.freeze,
        item_attributes: item_attributes.deep_dup.freeze
      )
    end
  end

  class << self
    def call(ocr_snapshot:)
      return unless ocr_snapshot.is_a?(Hash)
      return unless exact_candidate_counts?(ocr_snapshot)

      proposals = hash_value(
        ocr_snapshot,
        "adoption_proposals",
        maximum_entries: MAX_TOP_LEVEL_ENTRIES
      )
      stored_proposal = hash_value(
        proposals,
        "reference_pricing",
        maximum_entries: MAX_PROPOSAL_CONTAINER_ENTRIES
      )
      proposal = Receipts::Processing::Contracts::ReferencePricingAdoptionProposal.from_snapshot(
        stored_proposal,
        ocr_snapshot:
      )
      return if proposal.nil?

      name = destination_name(ocr_snapshot, proposal:)
      return if name.nil?

      Result.new(
        candidate_identity: proposal.fetch("candidate_id"),
        destination_identity: proposal.dig("destination", "identity"),
        item_attributes: item_attributes(name, proposal:)
      )
    rescue EncodingError, ArgumentError, KeyError, SystemStackError, TypeError
      nil
    end

    private

    def exact_candidate_counts?(snapshot)
      counts = hash_value(snapshot, "candidate_counts", maximum_entries: MAX_TOP_LEVEL_ENTRIES)
      exact_count?(
        hash_value(counts, "items", maximum_entries: MAX_NESTED_ENTRIES),
        expected: 0
      ) &&
        exact_count?(
          hash_value(counts, "reference_pricing_candidates", maximum_entries: MAX_NESTED_ENTRIES),
          expected: 1
        )
    end

    def exact_count?(value, expected:)
      return false unless value.is_a?(Hash) && value.size == ITEM_COUNT_KEYS.size

      actual = hash_value(value, "actual_count", maximum_entries: ITEM_COUNT_KEYS.size)
      snapshot = hash_value(value, "snapshot_count", maximum_entries: ITEM_COUNT_KEYS.size)
      actual == expected && snapshot == expected
    end

    def destination_name(snapshot, proposal:)
      destination = proposal.fetch("destination")
      line_index = destination.fetch("name_line_index")
      grapheme_length = destination.fetch("normalized_name_grapheme_length")
      lines = hash_value(snapshot, "case_preserved_lines", maximum_entries: MAX_TOP_LEVEL_ENTRIES)
      return unless lines.is_a?(Array) && lines.size <=
        Receipts::Processing::Contracts::ReferencePricingAdoptionProposal::MAX_CONTEXT_LINES

      line = lines[line_index]
      return unless line.is_a?(String) && line.valid_encoding?

      name = line.scan(/\X/).first(grapheme_length).join
      return unless name.present? && name.bytesize <= 96

      name
    end

    def item_attributes(name, proposal:)
      category = Analysis.detect_category(name)
      {
        raw_text: name,
        suggested_name: name,
        confirmed_name: nil,
        category: category,
        price: nil,
        quantity: proposal.dig("purchased_quantity", "amount"),
        quantity_unit_code: proposal.dig("purchased_quantity", "unit_code"),
        quantity_unit_raw: nil,
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: proposal.dig("reference_price", "amount"),
        reference_quantity: proposal.dig("reference_quantity", "amount"),
        reference_quantity_unit_code: proposal.dig("reference_quantity", "unit_code"),
        reference_quantity_unit_raw: nil,
        reference_price_tax_inclusion: "gross",
        original_line_total: nil,
        line_total: nil,
        discount_amount: nil,
        discount_rate: nil,
        quantity_unit_status: "known",
        tax_rate: nil,
        needs_review: category.nil?,
        review_reasons: category.nil? ? [ "item_category_uncertain" ] : [],
        position_index: 1,
        confidence: nil
      }
    end

    def hash_value(hash, expected_key, maximum_entries:)
      return unless hash.is_a?(Hash) && hash.size <= maximum_entries

      matching_keys = hash.keys.select do |key|
        (key.is_a?(String) || key.is_a?(Symbol)) && key.to_s == expected_key
      end
      return unless matching_keys.one?

      hash[matching_keys.sole]
    end
  end
end
