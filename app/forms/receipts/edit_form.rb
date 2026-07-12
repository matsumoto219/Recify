# frozen_string_literal: true

class Receipts::EditForm
  def self.call(receipt:, attributes:)
    Receipts::Editing::InputNormalizer.call(receipt: receipt, attributes: attributes)
  end
end
