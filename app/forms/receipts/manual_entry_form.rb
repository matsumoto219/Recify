# frozen_string_literal: true

class Receipts::ManualEntryForm
  def self.call(receipt:, attributes:)
    Receipts::Editing::InputNormalizer.call(receipt: receipt, attributes: attributes)
  end
end
