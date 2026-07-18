# frozen_string_literal: true

class Receipts::EditForm
  PURCHASE_INPUT_KEYS = %w[receipt_items_attributes receipt_adjustments_attributes].freeze

  def self.call(receipt:, attributes:)
    Receipts::Editing::InputNormalizer.call(receipt: receipt, attributes: attributes)
  end

  def self.purchase_inputs_changed?(receipt:, attributes:)
    purchase_attributes = attributes.to_h.slice(*PURCHASE_INPUT_KEYS)
    normalized = call(receipt: receipt, attributes: purchase_attributes)

    Receipts::Editing.change_set(
      receipt: receipt,
      permitted: normalized
    ).derived_purchase_inputs_changed?
  rescue Receipts::NumericInput::InvalidValue
    true
  end
end
