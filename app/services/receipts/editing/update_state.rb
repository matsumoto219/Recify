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

    attributes["processing_error_code"] = nil
    attributes["processing_error_message"] = nil
    attributes["status"] = "completed" if receipt.failed? && !attributes.key?("status")
  end
end
