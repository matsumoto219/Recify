class Receipts::Editing::UpdateState
  def self.call(receipt:, attributes:, review_state_arguments:)
    new(receipt:, attributes:, review_state_arguments:).call
  end

  def initialize(receipt:, attributes:, review_state_arguments:)
    @receipt = receipt
    @attributes = attributes
    @review_state_arguments = review_state_arguments
  end

  def call
    apply_review_state if review_state_arguments.present?
    clear_processing_error
    attributes
  end

  private

  attr_reader :receipt, :attributes, :review_state_arguments

  def apply_review_state
    review_state = Receipts::Editing::ReviewState.call(
      receipt: receipt,
      permitted: attributes,
      **review_state_arguments
    )
    attributes["review_reasons"] = review_state.review_reasons
    attributes["status"] = review_state.status
  end

  def clear_processing_error
    return unless receipt.has_processing_error?
    return if processing_error_is_only_review_explanation?

    attributes["processing_error_code"] = nil
    attributes["processing_error_message"] = nil
    attributes["status"] = "completed" if receipt.failed? && !attributes.key?("status")
  end

  def processing_error_is_only_review_explanation?
    return false if review_state_arguments.blank?

    resulting_status = attributes.fetch("status", receipt.status)
    return false unless resulting_status == "review_needed"

    resulting_reasons = attributes.fetch("review_reasons", receipt.review_reasons)
    ReviewReasons.review_reasons_for_user(resulting_reasons).empty? &&
      review_state_arguments&.fetch(:child_review_remaining, false) != true
  end
end
