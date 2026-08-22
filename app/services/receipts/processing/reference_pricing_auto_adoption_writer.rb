class Receipts::Processing::ReferencePricingAutoAdoptionWriter
  REASONS = %w[
    applied
    gate_disabled
    destination_invalid
    receipt_state_invalid
    build_params_conflict
    profile_unsupported
    adjustment_conflict
    ineligible
  ].freeze

  Result = Data.define(
    :applied,
    :reason,
    :params,
    :candidate_identity,
    :destination_identity
  ) do
    def initialize(applied:, reason:, params:, candidate_identity: nil, destination_identity: nil)
      super(
        applied: applied == true,
        reason: reason.to_s.dup.freeze,
        params: params.deep_dup,
        candidate_identity: candidate_identity&.dup&.freeze,
        destination_identity: destination_identity&.dup&.freeze
      )
    end

    def applied?
      applied == true
    end
  end

  class << self
    def call(receipt:, run:, params:, gate_result:, existing_items:)
      safe_params = normalized_params(params)
      return result("gate_disabled", params: safe_params) unless gate_result&.enabled?
      return result("receipt_state_invalid", params: safe_params) unless receipt&.processing?
      return result("build_params_conflict", params: safe_params) unless
        Array(safe_params[:receipt_items_attributes]).empty? && Array(existing_items).empty?
      return result("adjustment_conflict", params: safe_params) unless
        Array(safe_params[:receipt_adjustments_attributes]).empty?
      return result("profile_unsupported", params: safe_params) unless supported_profile?(receipt, safe_params)

      snapshot = run&.ocr_result_snapshot.to_h
      destination = Receipts::Processing::ReferencePricingAutoAdoptionDestination.call(
        ocr_snapshot: snapshot
      )
      return result("destination_invalid", params: safe_params) if destination.nil?
      return result("destination_invalid", params: safe_params) unless gate_identity_matches?(gate_result, destination:)

      gate = gate_snapshot(run)
      return result("ineligible", params: safe_params) if gate.nil?

      proposal = destination.proposal
      projection = projection_for(proposal)
      return result("ineligible", params: safe_params) unless
        projection && projected_total_matches?(safe_params, projection:)

      eligibility = Receipts::Processing::Contracts::ReferencePricingAutoAdoptionEligibility.call(
        ocr_snapshot: snapshot,
        proposals: [ proposal ],
        destinations: [
          {
            "candidate_identity" => destination.candidate_identity,
            "destination_identity" => destination.destination_identity
          }
        ],
        authority_state: "absent",
        expected_receipt_lock_version: gate.dig("proposal_binding", "receipt_lock_version"),
        current_receipt_lock_version: receipt.lock_version,
        projected_amount_limit: ReceiptAmountService.receipt_item_line_total_max
      )
      return result("ineligible", params: safe_params) unless eligibility.eligible?

      adopted_params = safe_params.deep_dup
      adopted_params[:receipt_items_attributes] = [ destination.item_attributes.deep_dup ]
      result(
        "applied",
        applied: true,
        params: adopted_params,
        candidate_identity: destination.candidate_identity,
        destination_identity: destination.destination_identity
      )
    rescue ArgumentError, KeyError, TypeError
      result("ineligible", params: normalized_params(params))
    end

    private

    def supported_profile?(receipt, params)
      attributes = normalized_hash(params[:receipt_attributes])
      receipt.country_region == "JPN" &&
        (receipt.currency_code.blank? || receipt.currency_code == "JPY") &&
        [ nil, "", "JPN" ].include?(attributes["country_region"]) &&
        attributes["currency_code"] == "JPY"
    end

    def gate_snapshot(run)
      Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot.from_snapshot(
        run.metadata.to_h[
          Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot::METADATA_KEY
        ],
        run:,
        require_binding: true
      )
    end

    def gate_identity_matches?(gate_result, destination:)
      gate_result.candidate_identity == destination.candidate_identity &&
        gate_result.destination_identity == destination.destination_identity
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

    def projected_total_matches?(params, projection:)
      total = normalized_hash(params[:receipt_attributes])["total_amount"]
      parsed = ReceiptAmountService.parse_amount_or_nil(total)
      parsed == projection.fetch(:projected_amount)
    end

    def normalized_params(value)
      return {} unless value.respond_to?(:to_h)

      value.to_h.deep_symbolize_keys
    rescue EncodingError, ArgumentError, TypeError
      {}
    end

    def normalized_hash(value)
      return {} unless value.respond_to?(:to_h)

      value.to_h.deep_stringify_keys
    rescue EncodingError, ArgumentError, TypeError
      {}
    end

    def result(reason, applied: false, params:, candidate_identity: nil, destination_identity: nil)
      bounded_reason = REASONS.include?(reason) ? reason : "ineligible"
      Result.new(
        applied:,
        reason: bounded_reason,
        params:,
        candidate_identity:,
        destination_identity:
      )
    end
  end
end
