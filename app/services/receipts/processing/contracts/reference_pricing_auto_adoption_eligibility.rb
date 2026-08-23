module Receipts::Processing::Contracts
  class ReferencePricingAutoAdoptionEligibility
    CONTRACT_VERSION = "reference_pricing_auto_adoption_eligibility_v1"
    ELIGIBLE_REASON = "eligible"
    REASONS = %w[
      eligible
      proposal_count_invalid
      proposal_invalid
      destination_count_invalid
      destination_identity_mismatch
      receipt_version_mismatch
      existing_authority
      partial_source_metadata
      authority_state_invalid
      projection_limit_invalid
      projection_out_of_bounds
    ].freeze
    AUTHORITY_STATES = %w[absent existing partial].freeze
    DESTINATION_KEYS = %w[candidate_identity destination_identity].freeze
    MAX_ID_BYTES = 160

    Result = Data.define(
      :eligible,
      :reason,
      :candidate_identity,
      :destination_identity,
      :contract_version
    ) do
      def initialize(eligible:, reason:, candidate_identity: nil, destination_identity: nil)
        super(
          eligible: eligible == true,
          reason: reason.to_s.dup.freeze,
          candidate_identity: candidate_identity&.dup&.freeze,
          destination_identity: destination_identity&.dup&.freeze,
          contract_version: CONTRACT_VERSION
        )
      end

      def eligible?
        eligible == true
      end
    end

    class << self
      def call(
        ocr_snapshot:,
        proposals:,
        destinations:,
        authority_state:,
        expected_receipt_lock_version:,
        current_receipt_lock_version:,
        projected_amount_limit:
      )
        return result("proposal_count_invalid") unless proposals.is_a?(Array) && proposals.one?

        proposal = ReferencePricingAdoptionProposal.from_snapshot(
          proposals.sole,
          ocr_snapshot:
        )
        return result("proposal_invalid") if proposal.nil?

        candidate_identity = proposal["candidate_id"]
        destination_identity = proposal.dig("destination", "identity")
        return result("destination_count_invalid", candidate_identity:, destination_identity:) unless
          destinations.is_a?(Array) && destinations.one?

        destination = exact_destination(destinations.sole)
        unless destination &&
            destination["candidate_identity"] == candidate_identity &&
            destination["destination_identity"] == destination_identity
          return result("destination_identity_mismatch", candidate_identity:, destination_identity:)
        end

        unless matching_lock_versions?(expected_receipt_lock_version, current_receipt_lock_version)
          return result("receipt_version_mismatch", candidate_identity:, destination_identity:)
        end

        case authority_state
        when "existing"
          return result("existing_authority", candidate_identity:, destination_identity:)
        when "partial"
          return result("partial_source_metadata", candidate_identity:, destination_identity:)
        when "absent"
          nil
        else
          return result("authority_state_invalid", candidate_identity:, destination_identity:)
        end

        unless valid_projection_limit?(projected_amount_limit)
          return result("projection_limit_invalid", candidate_identity:, destination_identity:)
        end

        projection = projection_for(proposal)
        unless projection && projection.fetch(:projected_amount) <= projected_amount_limit
          return result("projection_out_of_bounds", candidate_identity:, destination_identity:)
        end

        result(ELIGIBLE_REASON, eligible: true, candidate_identity:, destination_identity:)
      rescue ArgumentError, KeyError, TypeError
        result("proposal_invalid")
      end

      private

      def exact_destination(value)
        return unless value.is_a?(Hash) && value.size == DESTINATION_KEYS.size

        normalized = {}
        value.each do |key, child|
          return unless key.is_a?(String) || key.is_a?(Symbol)

          normalized_key = key.to_s
          return unless DESTINATION_KEYS.include?(normalized_key)
          return if normalized.key?(normalized_key)
          return unless bounded_identity?(child)

          normalized[normalized_key] = child
        end
        normalized if normalized.keys.sort == DESTINATION_KEYS.sort
      rescue EncodingError, ArgumentError, TypeError
        nil
      end

      def bounded_identity?(value)
        value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, MAX_ID_BYTES) &&
          !value.match?(ReferencePricingAdoptionProposal::CONTROL_CHARACTER_PATTERN)
      rescue EncodingError, ArgumentError, TypeError
        false
      end

      def matching_lock_versions?(expected, current)
        expected.is_a?(Integer) && expected >= 0 && current.is_a?(Integer) && current == expected
      end

      def valid_projection_limit?(value)
        value.is_a?(Integer) && value.between?(0, ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX.to_i)
      end

      def projection_for(proposal)
        ReceiptAmountService.reference_item_extension_projection(
          reference_price_amount: proposal.dig("reference_price", "amount"),
          reference_quantity: proposal.dig("reference_quantity", "amount"),
          reference_unit_code: proposal.dig("reference_quantity", "unit_code"),
          purchased_quantity: proposal.dig("purchased_quantity", "amount"),
          purchased_unit_code: proposal.dig("purchased_quantity", "unit_code")
        )
      rescue ReceiptAmountService::InvalidItemSourceError
        nil
      end

      def result(reason, eligible: false, candidate_identity: nil, destination_identity: nil)
        bounded_reason = REASONS.include?(reason) ? reason : "proposal_invalid"
        Result.new(eligible:, reason: bounded_reason, candidate_identity:, destination_identity:)
      end
    end
  end
end
