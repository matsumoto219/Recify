class Receipts::Processing::StatusTransition
  def self.mark_processing!(receipt)
    receipt.update!(
      status: "processing",
      processing_error_code: nil,
      processing_error_message: nil,
      review_reasons: []
    )
  end
end
