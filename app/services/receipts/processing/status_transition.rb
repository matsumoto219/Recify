class Receipts::Processing::StatusTransition
  def self.reset_for_retry!(receipt)
    receipt.with_lock do
      %i[receipt_items receipt_tax_details receipt_payments receipt_adjustments].each do |association_name|
        receipt.public_send(association_name).destroy_all
      end
      receipt.assign_attributes(
        store_name: nil,
        store_address: nil,
        store_address_components: {},
        store_phone_number: nil,
        purchased_at: nil,
        receipt_type: nil,
        country_region: nil,
        currency_code: nil,
        payment_method: nil,
        subtotal_amount: nil,
        tax_amount: nil,
        tax_rate: nil,
        tip_amount: nil,
        total_amount: nil,
        ocr_completed_at: nil,
        amount_calculation_profile: {}
      )
      mark_processing!(receipt)
    end
  end

  def self.mark_processing!(receipt)
    receipt.update!(
      status: "processing",
      processing_error_code: nil,
      processing_error_message: nil,
      review_reasons: []
    )
  end
end
